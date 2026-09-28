# frozen_string_literal: true

module Ask
  module AGUI
    # Per-thread run bookkeeping backing `POST /agent/:id/connect`
    # (replay) and `POST /agent/:id/stop/:thread_id` (cooperative cancel).
    #
    # The interface is duck-typed: anything implementing {#begin_run},
    # {#record}, {#finish_run}, {#replay}, {#request_stop} and
    # {#stop_requested?} works as a store. A future shared store (Redis,
    # database) can be dropped in without touching the server.
    #
    #   store.begin_run("t1", "r1")
    #   store.record("t1", "data: {...}\n\n")
    #   store.finish_run("t1")
    #   store.replay("t1")            # => ["data: {...}\n\n", ...]
    #   store.request_stop("t1")      # => true
    #   store.stop_requested?("t1")   # => true
    module RunStore
      # Single-process in-memory store.
      #
      # NOTE: frames live in this process's memory only. Two processes
      # (two Puma workers, two machines) cannot see each other's runs, so
      # `/connect` replay and `/stop` only work when the client keeps
      # hitting the same process. Back replay and stop with a shared store
      # when running more than one process.
      #
      # Mutex-guarded, so threads sharing one process are safe.
      class InMemory
        # Build an empty store.
        def initialize
          @mutex = Mutex.new
          @frames = Hash.new { |hash, key| hash[key] = [] }
          @stop_requested = {}
        end

        # Mark the start of a run. Clears any stale stop request for the
        # thread so a previous `/stop` cannot cancel the new run.
        #
        # @param thread_id [String]
        # @param run_id [String]
        # @return [void]
        def begin_run(thread_id, run_id)
          @mutex.synchronize do
            @stop_requested.delete(thread_id.to_s)
          end
          nil
        end

        # Append one SSE frame for later `/connect` replay.
        #
        # @param thread_id [String]
        # @param frame [String] one `"data: <json>\n\n"` frame.
        # @return [void]
        def record(thread_id, frame)
          @mutex.synchronize do
            @frames[thread_id.to_s] << frame
          end
          nil
        end

        # Mark the run finished. Frames stay available for replay.
        #
        # @param thread_id [String]
        # @return [void]
        def finish_run(thread_id)
          nil
        end

        # Answer every frame recorded for the thread, in order.
        #
        # @param thread_id [String]
        # @return [Array<String>] possibly empty when nothing was recorded.
        def replay(thread_id)
          @mutex.synchronize do
            @frames[thread_id.to_s].dup
          end
        end

        # Flag the thread's run for cooperative cancel. The run loop
        # checks {#stop_requested?} between events and ends the run early.
        #
        # @param thread_id [String]
        # @return [true]
        def request_stop(thread_id)
          @mutex.synchronize do
            @stop_requested[thread_id.to_s] = true
          end
          true
        end

        alias stop request_stop

        # Whether {#request_stop} was called since the last {#begin_run}.
        #
        # @param thread_id [String]
        # @return [Boolean]
        def stop_requested?(thread_id)
          @mutex.synchronize do
            @stop_requested.fetch(thread_id.to_s, false)
          end
        end
      end
    end
  end
end
