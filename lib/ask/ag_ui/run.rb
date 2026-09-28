# frozen_string_literal: true

require "json"
require "ag_ui_protocol"

module Ask
  module AGUI
    # The parsed AG-UI run input for one `POST /agent/:id/run`.
    #
    # The server parses the request body into a Run and hands it to the
    # host's block. The host reads what it needs (messages, tools, context,
    # forwarded props) and answers the stream of duck-typed agent events;
    # the server drives one {Emitter} with those events and owns the socket.
    #
    # Message, tool, and context entries are coerced to their
    # `AgUiProtocol::Core::Types` counterparts on a best-effort basis:
    # entries that do not coerce are skipped, never fatal. `state` and
    # `forwarded_props` are opaque user data and ride through verbatim.
    class Run
      # Raised on malformed JSON or a missing `threadId` / `runId`. The
      # server renders this as `400 {"error": ..., "details": ...}`.
      class InvalidError < StandardError; end

      # @return [String] the `:id` segment of `/agent/:id/run`.
      attr_reader :agent_id

      # @return [String] the AG-UI thread id.
      attr_reader :thread_id

      # @return [String] the AG-UI run id.
      attr_reader :run_id

      # @return [Array<AgUiProtocol::Core::Types::BaseMessage,
      #   AgUiProtocol::Core::Types::ActivityMessage>] coerced input messages.
      attr_reader :messages

      # @return [Array<AgUiProtocol::Core::Types::Tool>] coerced tools.
      attr_reader :tools

      # @return [Array<AgUiProtocol::Core::Types::Context>] coerced context.
      attr_reader :context

      # @return [Object] opaque forwarded props, verbatim from the client.
      attr_reader :forwarded_props

      # @return [Object] opaque agent state, verbatim from the client.
      attr_reader :state

      # @return [Hash] the raw parsed body.
      attr_reader :raw

      # @param agent_id [String]
      # @param thread_id [String]
      # @param run_id [String]
      # @param messages [Array]
      # @param tools [Array]
      # @param context [Array]
      # @param forwarded_props [Object]
      # @param state [Object]
      # @param raw [Hash]
      def initialize(agent_id:, thread_id:, run_id:, messages: [], tools: [],
                     context: [], forwarded_props: nil, state: nil, raw: {})
        @agent_id = agent_id
        @thread_id = thread_id
        @run_id = run_id
        @messages = messages
        @tools = tools
        @context = context
        @forwarded_props = forwarded_props
        @state = state
        @raw = raw
      end

      # Parse a `POST /agent/:id/run` body into a Run.
      #
      # @param agent_id [String] the `:id` segment of the request path.
      # @param body [String] the raw request body.
      # @return [Run]
      # @raise [InvalidError] when the body is not a JSON object carrying
      #   string `threadId` and `runId` members.
      def self.parse(agent_id, body)
        raw = begin
          JSON.parse(body.to_s)
        rescue JSON::ParserError => e
          raise InvalidError, "malformed JSON: #{e.message}"
        end

        unless raw.is_a?(Hash)
          raise InvalidError, "expected a JSON object, got #{raw.class}"
        end

        thread_id = raw["threadId"] || raw["thread_id"]
        run_id = raw["runId"] || raw["run_id"]

        unless thread_id.is_a?(String) && !thread_id.empty?
          raise InvalidError, "missing required member \"threadId\""
        end

        unless run_id.is_a?(String) && !run_id.empty?
          raise InvalidError, "missing required member \"runId\""
        end

        new(
          agent_id: agent_id.to_s,
          thread_id: thread_id,
          run_id: run_id,
          messages: coerce_messages(raw["messages"]),
          tools: coerce_tools(raw["tools"]),
          context: coerce_context(raw["context"]),
          forwarded_props: raw.key?("forwardedProps") ? raw["forwardedProps"] : raw["forwarded_props"],
          state: raw["state"],
          raw: raw
        )
      end

      # Best-effort message coercion. Unknown roles and malformed entries
      # are skipped so one bad message cannot fail the run.
      #
      # @param value [Object]
      # @return [Array]
      def self.coerce_messages(value)
        return [] unless value.is_a?(Array)

        value.filter_map do |entry|
          coerce_message(entry)
        rescue StandardError
          nil
        end
      end

      # Coerce one raw message hash to its protocol type.
      #
      # @param entry [Object]
      # @return [AgUiProtocol::Core::Types::Model, nil]
      def self.coerce_message(entry)
        return nil unless entry.is_a?(Hash)

        types = AgUiProtocol::Core::Types
        id = (entry["id"] || entry[:id]).to_s
        return nil if id.empty?

        case entry["role"] || entry[:role]
        when "user"
          types::UserMessage.new(id: id, content: entry["content"] || entry[:content] || "")
        when "assistant"
          types::AssistantMessage.new(
            id: id,
            content: entry["content"] || entry[:content],
            tool_calls: entry["toolCalls"] || entry["tool_calls"] || entry[:tool_calls]
          )
        when "system"
          types::SystemMessage.new(id: id, content: (entry["content"] || entry[:content]).to_s)
        when "developer"
          types::DeveloperMessage.new(id: id, content: (entry["content"] || entry[:content]).to_s)
        when "tool"
          tool_call_id = entry["toolCallId"] || entry["tool_call_id"] || entry[:tool_call_id]
          return nil if tool_call_id.to_s.empty?

          types::ToolMessage.new(
            id: id,
            content: (entry["content"] || entry[:content]).to_s,
            tool_call_id: tool_call_id.to_s
          )
        when "activity"
          content = entry["content"] || entry[:content]
          return nil unless content.is_a?(Hash)

          types::ActivityMessage.new(
            id: id,
            activity_type: (entry["activityType"] || entry["activity_type"] || "activity").to_s,
            content: content
          )
        when "reasoning"
          types::ReasoningMessage.new(id: id, content: (entry["content"] || entry[:content]).to_s)
        end
      rescue StandardError
        nil
      end

      # @param value [Object]
      # @return [Array<AgUiProtocol::Core::Types::Tool>]
      def self.coerce_tools(value)
        return [] unless value.is_a?(Array)

        types = AgUiProtocol::Core::Types
        value.filter_map do |entry|
          next unless entry.is_a?(Hash)

          name = entry["name"] || entry[:name]
          description = entry["description"] || entry[:description]
          parameters = entry["parameters"] || entry[:parameters]
          next if name.to_s.empty?

          types::Tool.new(
            name: name.to_s,
            description: description.to_s,
            parameters: parameters.nil? ? {} : parameters
          )
        rescue StandardError
          nil
        end
      end

      # @param value [Object]
      # @return [Array<AgUiProtocol::Core::Types::Context>]
      def self.coerce_context(value)
        return [] unless value.is_a?(Array)

        types = AgUiProtocol::Core::Types
        value.filter_map do |entry|
          next unless entry.is_a?(Hash)

          description = entry["description"] || entry[:description]
          content = entry["value"] || entry[:value]
          next if description.to_s.empty? || content.nil?

          types::Context.new(description: description.to_s, value: content.to_s)
        rescue StandardError
          nil
        end
      end

      private_class_method :coerce_message
    end
  end
end
