# frozen_string_literal: true

require "json"
require "securerandom"
require "ag_ui_protocol"

module Ask
  module AGUI
    # The seam between ask-rb agent/session events and the AG-UI protocol.
    #
    # A transport drives one Emitter per run: it hands the emitter the AG-UI
    # run context (thread id, run id, input messages), feeds it the stream of
    # agent events via {#handle}, and collects the SSE frames it returns.
    # The transport owns the socket; the emitter only translates and encodes.
    #
    #   emitter = Ask::AGUI::Emitter.new(thread_id: "t1", run_id: "r1", messages: [...])
    #   frames = emitter.handle(agent_event)  # => ["data: {...}\n\n", ...]
    #   frames = emitter.finish               # => ["data: {\"type\":\"RUN_FINISHED\",...}\n\n"]
    #
    # Event vocabulary (matched by class name, so the emitter never depends
    # on ask-agent — any duck-typed object with the same shape works):
    #
    # * `TurnStart` / `SessionStart` → `RUN_STARTED` (first one wins)
    # * `TextDelta` (`content`) → `TEXT_MESSAGE_START`, then
    #   `TEXT_MESSAGE_CONTENT` per delta (only empty deltas are dropped — a
    #   space is content, and dropping it would fuse the words around it),
    #   then `TEXT_MESSAGE_END` on `MessageEnd`
    # * `ThinkingDelta` (`content`) → `REASONING_START` →
    #   `REASONING_MESSAGE_START` → `REASONING_MESSAGE_CONTENT` per delta
    #   (empty deltas dropped) → `REASONING_MESSAGE_END` → `REASONING_END`
    #   on `MessageEnd`
    # * `ToolCallDelta` (`name`, `arguments`, `id`) → `TOOL_CALL_START`
    #   (once per id) → `TOOL_CALL_ARGS` per non-empty delta;
    #   `ToolExecutionStart` opens calls the stream never announced;
    #   `MessageEnd` closes open calls with `TOOL_CALL_END`;
    #   `ToolExecutionEnd` (`name`, `id`, `result`, …) closes the call if
    #   still open and emits `TOOL_CALL_RESULT`
    # * `SessionEnd` → `RUN_FINISHED` (first one wins); `Error` (`error`) →
    #   `RUN_ERROR`. {#finish} and {#fail} drive the same endings manually.
    # * Anything else rides one generic `CUSTOM` passthrough
    #   (`name` = event class name, `value` = its `to_h`): the emitter knows
    #   nothing about any chat application's specific states. A host with
    #   its own state vocabulary renames those frames by overriding
    #   {#custom_name} — no private method to reach for.
    #
    # `MessageEnd` and `TurnEnd` carry no AG-UI counterpart of their own —
    # they only close whatever text, reasoning, or tool call is still open.
    #
    # Every frame is built with `AgUiProtocol::Core::Events::*` and encoded
    # with `AgUiProtocol::Encoder::EventEncoder` — event JSON is never
    # hand-rolled. Each {#handle}/{#start}/{#finish}/{#fail} call answers an
    # array of `"data: <json>\n\n"` SSE frame strings (possibly empty).
    class Emitter
      # @return [String] the AG-UI thread this emitter streams for.
      attr_reader :thread_id

      # @return [String] the AG-UI run this emitter streams for.
      attr_reader :run_id

      # @param thread_id [String] AG-UI thread id (echoed on RUN_STARTED/RUN_FINISHED).
      # @param run_id [String] AG-UI run id (echoed on RUN_STARTED/RUN_FINISHED).
      # @param messages [Array<AgUiProtocol::Core::Types::BaseMessage,
      #   AgUiProtocol::Core::Types::ActivityMessage>] input messages carried
      #   on the RUN_STARTED event.
      # @param custom_names [Hash] the host's own `CUSTOM` frame names, keyed
      #   by the event's class name (`"VisitorAway" => "resting"`). Events
      #   left out keep the default. See {#custom_name}.
      def initialize(thread_id:, run_id:, messages: [], custom_names: {})
        @thread_id = thread_id
        @run_id = run_id
        @input = AgUiProtocol::Core::Types::RunAgentInput.new(
          thread_id: thread_id,
          run_id: run_id,
          state: {},
          messages: messages,
          tools: [],
          context: [],
          forwarded_props: {}
        )
        @custom_names = normalize_custom_names(custom_names)
        @encoder = AgUiProtocol::Encoder::EventEncoder.new
        @started = false
        @terminal = false
        @text_message_id = nil
        @reasoning_message_id = nil
        @seen_tool_calls = []
        @open_tool_calls = []
      end

      # Feed one agent event through the translator.
      #
      # @param event [Object] a duck-typed agent event (see class docs).
      # @return [Array<String>] SSE frames to write to the stream, in order.
      def handle(event)
        case event_name(event)
        when "TurnStart", "SessionStart"
          start
        when "TextDelta"
          handle_text_delta(event)
        when "ThinkingDelta"
          handle_reasoning_delta(event)
        when "ToolCallDelta"
          handle_tool_call_delta(event)
        when "ToolExecutionStart"
          handle_tool_execution_start(event)
        when "ToolExecutionEnd"
          handle_tool_execution_end(event)
        when "MessageEnd", "TurnEnd"
          close_open_messages
        when "SessionEnd"
          finish
        when "Error"
          fail_with(event_error(event))
        else
          handle_custom(event)
        end
      end

      # Open the run. Idempotent: only the first call emits RUN_STARTED.
      #
      # @return [Array<String>] zero or one SSE frames.
      def start
        return [] if @started

        @started = true
        [encode(AgUiProtocol::Core::Events::RunStartedEvent.new(
          thread_id: @thread_id, run_id: @run_id, input: @input
        ))]
      end

      # Close the run normally. Closes any open message first, then emits
      # RUN_FINISHED once — late calls only close stragglers.
      #
      # @return [Array<String>] SSE frames to write to the stream, in order.
      def finish
        frames = close_open_messages
        return frames if @terminal

        @terminal = true
        frames << encode(AgUiProtocol::Core::Events::RunFinishedEvent.new(
          thread_id: @thread_id, run_id: @run_id
        ))
        frames
      end

      # Close the run with an error. Accepts an exception, a message string,
      # or a duck-typed `Error` event (anything answering `error`).
      # Idempotent like {#finish}; after a terminal event the run stays shut.
      #
      # @param reason [Exception, String, Object] what went wrong.
      # @return [Array<String>] SSE frames to write to the stream, in order.
      def fail(reason)
        fail_with(reason)
      end

      # The `CUSTOM` frame name an app-defined event rides as.
      #
      # This is the seam for a host that has a state vocabulary of its own —
      # a chat page reading "resting", "done", "visitor_spent" instead of
      # the event classes. Two ways in, both public:
      #
      #   # 1. name the kinds you know, at construction:
      #   emitter = Ask::AGUI::Emitter.new(thread_id: "t1", run_id: "r1",
      #     custom_names: { "VisitorAway" => "resting", "CheckoutClosed" => "visitor_spent" })
      #
      #   # 2. override this method when the name is computed:
      #   class ChatEmitter < Ask::AGUI::Emitter
      #     NAMES = { "VisitorAway" => "resting" }
      #
      #     def custom_name(event)
      #       NAMES.fetch(event.class.name.split("::").last) { super }
      #     end
      #   end
      #
      # Either way only the frame's `name` changes: the event still rides
      # one `CUSTOM` frame with its `to_h` as the value, and the rest of
      # the vocabulary is untouched. An event nobody names — or a name that
      # comes back nil or empty — falls back to the event's class name, so
      # the default is exactly what it is without any of this.
      #
      # @param event [Object] the app-defined event about to ride a frame.
      # @return [String] the `name` that frame carries.
      def custom_name(event)
        name = event_name(event)
        custom = @custom_names[name]
        custom.to_s.empty? ? name : custom.to_s
      end

      private

      # The host's names, keyed by event class name, normalized once so
      # `{ VisitorAway: :resting }` reads like `{ "VisitorAway" => "resting" }`.
      def normalize_custom_names(custom_names)
        custom_names.to_h { |kind, name| [kind.to_s, name.to_s] }.freeze
      end

      # The key the emitter matches an event by — the event's demodulized
      # class name. Internal: renaming a `CUSTOM` frame is {#custom_name}'s
      # job, and renaming the vocabulary would move the mapping itself.
      def event_name(event)
        event.class.name.to_s.split("::").last
      end

      def fail_with(reason)
        frames = close_open_messages
        return frames if @terminal

        @terminal = true
        frames << encode(AgUiProtocol::Core::Events::RunErrorEvent.new(message: error_message(reason)))
        frames
      end

      def handle_text_delta(event)
        frames = start
        delta = event.respond_to?(:content) ? event.content : nil
        return frames if delta.to_s.empty?

        unless @text_message_id
          @text_message_id = SecureRandom.uuid
          frames << encode(AgUiProtocol::Core::Events::TextMessageStartEvent.new(message_id: @text_message_id))
        end
        frames << encode(AgUiProtocol::Core::Events::TextMessageContentEvent.new(
          message_id: @text_message_id, delta: delta.to_s
        ))
        frames
      end

      def handle_reasoning_delta(event)
        frames = start
        delta = event.respond_to?(:content) ? event.content : nil
        return frames if delta.to_s.empty?

        unless @reasoning_message_id
          @reasoning_message_id = SecureRandom.uuid
          frames << encode(AgUiProtocol::Core::Events::ReasoningStartEvent.new(message_id: @reasoning_message_id))
          frames << encode(AgUiProtocol::Core::Events::ReasoningMessageStartEvent.new(
            message_id: @reasoning_message_id
          ))
        end
        frames << encode(AgUiProtocol::Core::Events::ReasoningMessageContentEvent.new(
          message_id: @reasoning_message_id, delta: delta.to_s
        ))
        frames
      end

      def handle_tool_call_delta(event)
        frames = start
        id = event_id(event)
        open_tool_call(frames, id: id, name: event_name_or(event, id), parent_message_id: @text_message_id)
        args = args_delta(event_arguments(event))
        frames << encode(AgUiProtocol::Core::Events::ToolCallArgsEvent.new(tool_call_id: id, delta: args)) if args
        frames
      end

      def handle_tool_execution_start(event)
        frames = start
        id = event_id(event)
        return frames if @seen_tool_calls.include?(id)

        open_tool_call(frames, id: id, name: event_name_or(event, id), parent_message_id: @text_message_id)
        args = args_delta(event_arguments(event))
        frames << encode(AgUiProtocol::Core::Events::ToolCallArgsEvent.new(tool_call_id: id, delta: args)) if args
        frames
      end

      def handle_tool_execution_end(event)
        frames = start
        id = event_id(event)
        unless @seen_tool_calls.include?(id)
          open_tool_call(frames, id: id, name: event_name_or(event, id), parent_message_id: @text_message_id)
        end
        if @open_tool_calls.delete(id)
          frames << encode(AgUiProtocol::Core::Events::ToolCallEndEvent.new(tool_call_id: id))
        end
        frames << encode(AgUiProtocol::Core::Events::ToolCallResultEvent.new(
          message_id: SecureRandom.uuid, tool_call_id: id, content: result_content(event_result(event)), role: "tool"
        ))
        frames
      end

      def handle_custom(event)
        value = event.respond_to?(:to_h) ? event.to_h : {}
        value = {} if value.nil?
        [encode(AgUiProtocol::Core::Events::CustomEvent.new(name: custom_name(event), value: value))]
      end

      def close_open_messages
        frames = []
        if @reasoning_message_id
          frames << encode(AgUiProtocol::Core::Events::ReasoningMessageEndEvent.new(message_id: @reasoning_message_id))
          frames << encode(AgUiProtocol::Core::Events::ReasoningEndEvent.new(message_id: @reasoning_message_id))
          @reasoning_message_id = nil
        end
        if @text_message_id
          frames << encode(AgUiProtocol::Core::Events::TextMessageEndEvent.new(message_id: @text_message_id))
          @text_message_id = nil
        end
        @open_tool_calls.each do |id|
          frames << encode(AgUiProtocol::Core::Events::ToolCallEndEvent.new(tool_call_id: id))
        end
        @open_tool_calls = []
        frames
      end

      def open_tool_call(frames, id:, name:, parent_message_id:)
        return if @seen_tool_calls.include?(id)

        @seen_tool_calls << id
        @open_tool_calls << id
        frames << encode(AgUiProtocol::Core::Events::ToolCallStartEvent.new(
          tool_call_id: id, tool_call_name: name, parent_message_id: parent_message_id
        ))
      end

      def encode(event)
        @encoder.encode(event)
      end

      def event_id(event)
        event.respond_to?(:id) ? event.id.to_s : SecureRandom.uuid
      end

      def event_name_or(event, fallback)
        name = event.respond_to?(:name) ? event.name : nil
        name = nil if name.to_s.empty?
        name ? name.to_s : fallback
      end

      def event_arguments(event)
        event.respond_to?(:arguments) ? event.arguments : nil
      end

      def event_result(event)
        event.respond_to?(:result) ? event.result : nil
      end

      def event_error(event)
        event.respond_to?(:error) ? event.error : event
      end

      def error_message(reason)
        if reason.is_a?(Exception)
          reason.message
        elsif reason.respond_to?(:error)
          reason.error.to_s
        else
          reason.to_s
        end
      end

      # Tool arguments arrive as a JSON string or a Hash — the wire wants a
      # string delta. Answers nil when there is nothing to send.
      def args_delta(arguments)
        return nil if arguments.nil?
        return nil if arguments.respond_to?(:empty?) && arguments.empty?

        delta = arguments.is_a?(String) ? arguments : JSON.generate(arguments)
        delta.empty? ? nil : delta
      end

      # Tool results arrive as the executor's legacy hash ({message:, result:,
      # …}), a plain string, or a duck-typed object — the wire wants a string.
      def result_content(result)
        return result.to_s if result.nil? || result.is_a?(String)

        hash = result_hash(result)
        if hash
          content = hash[:message] || hash["message"] || hash[:result] || hash["result"]
          return content.to_s unless content.nil?
        end
        result.to_s
      end

      def result_hash(result)
        return result if result.is_a?(Hash)
        return result.to_h if result.respond_to?(:to_h)

        nil
      end
    end
  end
end
