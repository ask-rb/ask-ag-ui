# frozen_string_literal: true

require "json"
require "ag_ui_protocol"

module Ask
  module AGUI
    # Mountable Rack application serving the AG-UI runtime surface.
    #
    # This is the conventional surface third-party AG-UI clients
    # (assistant-ui, CopilotKit) expect when pointed at the gem:
    #
    # * `GET /info` — the runtime envelope: the agents map (name, class,
    #   capabilities), the transport mode, and the gem version.
    # * `POST /agent/:id/run` — parses the run input, drives one {Emitter}
    #   for the run, and streams its SSE frames.
    # * `POST /agent/:id/connect` — replays recorded frames, or completes
    #   immediately when there is nothing to replay.
    # * `POST /agent/:id/stop/:thread_id` — flags the run for cooperative
    #   cancel and answers a JSON acknowledgement.
    #
    # The host supplies the work as a block and owns the agent; the gem
    # owns the socket and the framing and never depends on Rails or
    # ask-agent:
    #
    #   app = Ask::AGUI::Server.new(agent_id: "default") do |run|
    #     # run.thread_id, run.run_id, run.messages, run.tools,
    #     # run.context, run.forwarded_props — answer agent events:
    #     [TurnStart.new, TextDelta.new(content: "Hello")]
    #   end
    #
    # The block answers an enumerable of duck-typed agent events (the same
    # vocabulary {Emitter} handles). It may answer a lazy enumerator — the
    # response body pulls events only as it streams, so the run streams
    # under any Rack server. Every run opens with `RUN_STARTED` and closes
    # with `RUN_FINISHED` / `RUN_ERROR`, even when the host answers no
    # events or raises mid-run.
    #
    # Matching is on trailing path segments, so the app works standalone
    # and mounted (`map("/api/copilotkit") { run app }`, Rails `mount`).
    class Server
      # Response headers for the SSE streams. Matches the reference
      # runtime: `text/event-stream`, no caching, keep-alive.
      SSE_HEADERS = {
        "content-type" => "text/event-stream",
        "cache-control" => "no-cache",
        "connection" => "keep-alive",
        "x-accel-buffering" => "no"
      }.freeze

      # Response headers for the JSON endpoints.
      JSON_HEADERS = { "content-type" => "application/json" }.freeze

      AGENT_RUN_ROUTE = %r{/agent/(?<agent_id>[^/]+)/run\z}
      AGENT_CONNECT_ROUTE = %r{/agent/(?<agent_id>[^/]+)/connect\z}
      AGENT_STOP_ROUTE = %r{/agent/(?<agent_id>[^/]+)/stop/(?<thread_id>[^/]+)\z}
      INFO_ROUTE = %r{(?:\A|/)info\z}

      # @return [String] the agent id advertised on `GET /info`.
      attr_reader :agent_id

      # Build the Rack application.
      #
      # @param agent_id [String] the agent name advertised on `GET /info`.
      # @param description [String, nil] one-line agent description for discovery UIs.
      # @param agent_class_name [String] the agent class named on `GET /info`.
      # @param capabilities [AgUiProtocol::Core::Capabilities::AgentCapabilities, nil]
      #   capability information for `GET /info`. Defaults to what the
      #   {Emitter} actually drives: SSE transport, client-provided tools,
      #   streaming reasoning.
      # @param store [Ask::AGUI::RunStore::InMemory, nil] run bookkeeping
      #   for `/connect` replay and `/stop`. Pass `nil` for the stateless
      #   behaviour (connect completes immediately, stop only acks).
      # @yield [Run] the run input; answers an enumerable of agent events.
      # @raise [ArgumentError] when no run-handler block is given.
      def initialize(agent_id: "default", description: nil, agent_class_name: "BuiltInAgent",
                     capabilities: nil, store: RunStore::InMemory.new, &block)
        raise ArgumentError, "Server requires a run-handler block" unless block

        @agent_id = agent_id.to_s
        @description = description
        @agent_class_name = agent_class_name.to_s
        @capabilities = capabilities || default_capabilities
        @store = store
        @handler = block
      end

      # Rack entrypoint.
      #
      # @param env [Hash] the Rack environment.
      # @return [Array(Integer, Hash, Object)] the Rack response.
      def call(env)
        method = env["REQUEST_METHOD"].to_s
        path = env["PATH_INFO"].to_s.chomp("/")

        if method == "OPTIONS"
          return preflight
        elsif method == "GET" && path.match?(INFO_ROUTE)
          return respond_info
        elsif method == "POST" && (match = path.match(AGENT_STOP_ROUTE))
          return respond_stop(match[:thread_id])
        elsif method == "POST" && (match = path.match(AGENT_RUN_ROUTE))
          return respond_run(env, match[:agent_id])
        elsif method == "POST" && (match = path.match(AGENT_CONNECT_ROUTE))
          return respond_connect(env)
        end

        not_found
      end

      private

      def respond_info
        [200, JSON_HEADERS.dup, [JSON.generate(info_payload)]]
      end

      # The capability information is built from ag-ui-protocol's
      # capability and identity types — never hand-rolled.
      def info_payload
        agent = {
          "name" => @agent_id,
          "className" => @agent_class_name,
          "capabilities" => @capabilities.as_json
        }
        agent["description"] = @description unless @description.nil?

        {
          "agents" => { @agent_id => agent },
          "mode" => "sse",
          "version" => VERSION
        }
      end

      def default_capabilities
        capabilities = AgUiProtocol::Core::Capabilities
        capabilities::AgentCapabilities.new(
          identity: capabilities::IdentityCapabilities.new(
            name: @agent_id, description: @description, version: VERSION
          ),
          transport: capabilities::TransportCapabilities.new(streaming: true),
          tools: capabilities::ToolsCapabilities.new(supported: true, client_provided: true),
          reasoning: capabilities::ReasoningCapabilities.new(supported: true, streaming: true)
        )
      end

      def respond_run(env, agent_id)
        body = env["rack.input"]&.read.to_s
        run = Run.parse(agent_id, body)
        emitter = Emitter.new(thread_id: run.thread_id, run_id: run.run_id, messages: run.messages)
        [200, SSE_HEADERS.dup, run_body(run, emitter)]
      rescue Run::InvalidError => e
        bad_request(e.message)
      end

      # The enumerable body pulls the host's events lazily, translates
      # each through the emitter, and yields ready-to-write SSE frames —
      # plain Rack 3 streaming with no async requirement.
      def run_body(run, emitter)
        server = self
        Enumerator.new do |yielder|
          server.send(:stream_run, run, emitter, yielder)
        end
      end

      def stream_run(run, emitter, yielder)
        @store&.begin_run(run.thread_id, run.run_id)
        emit = lambda do |frames|
          frames.each do |frame|
            @store&.record(run.thread_id, frame)
            yielder << frame
          end
        end

        emit.call(emitter.start)

        events = @handler.call(run)
        events = [] if events.nil?
        events = [events] unless events.respond_to?(:each)
        events.each do |event|
          break if @store&.stop_requested?(run.thread_id)

          emit.call(emitter.handle(event))
        end

        emit.call(emitter.finish)
      rescue StandardError => e
        begin
          emit.call(emitter.fail(e))
        rescue StandardError
          nil
        end
      ensure
        @store&.finish_run(run.thread_id)
      end

      # Resume/reattach: replay everything recorded for the thread, then
      # close. Unknown thread (or no store) answers 200 SSE with zero
      # events — the client's reconnect stays well behaved.
      def respond_connect(env)
        thread_id = extract_thread_id(env["rack.input"]&.read.to_s)
        frames = (thread_id && @store) ? @store.replay(thread_id) : []
        [200, SSE_HEADERS.dup, frames]
      end

      # Flag the thread's run for cooperative cancel and ack. The run loop
      # checks the flag between events and ends the run early.
      def respond_stop(thread_id)
        stopped = @store ? @store.request_stop(thread_id.to_s) : false
        [200, JSON_HEADERS.dup, [JSON.generate({ "stopped" => stopped })]]
      end

      # `/connect` bodies carry the run input plus an optional replay
      # cursor — parsed opportunistically, never fatal.
      def extract_thread_id(body)
        return nil if body.empty?

        raw = JSON.parse(body)
        return nil unless raw.is_a?(Hash)

        thread_id = raw["threadId"] || raw["thread_id"]
        thread_id.is_a?(String) && !thread_id.empty? ? thread_id : nil
      rescue JSON::ParserError
        nil
      end

      def preflight
        [204, {
          "access-control-allow-origin" => "*",
          "access-control-allow-methods" => "GET, POST, OPTIONS",
          "access-control-allow-headers" => "*"
        }, []]
      end

      def bad_request(details)
        [400, JSON_HEADERS.dup,
         [JSON.generate({ "error" => "Invalid request body", "details" => details })]]
      end

      def not_found
        [404, JSON_HEADERS.dup, [JSON.generate({ "error" => "Not found" })]]
      end
    end
  end
end
