# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "json_schemer"

# Duck-typed stand-ins for the ask-agent event vocabulary. The emitter must
# never require ask-agent — it matches these by class name and shape, so
# same-named fakes exercise the exact seam a transport drives.
module AgentEvents
  TextDelta = Data.define(:content)
  ThinkingDelta = Data.define(:content)
  ToolCallDelta = Data.define(:name, :arguments, :id)
  ToolExecutionStart = Data.define(:name, :arguments, :id)
  ToolExecutionEnd = Data.define(:name, :id, :result, :is_error, :duration_ms)
  TurnStart = Data.define
  TurnEnd = Data.define(:tool_results, :turn_number, :input_tokens, :output_tokens, :cost)
  MessageEnd = Data.define(:tool_calls)
  SessionEnd = Data.define(:result, :turn_count, :tool_calls_made, :input_tokens, :output_tokens, :cost)
  Error = Data.define(:error, :recoverable)

  # App-defined state the gem must know nothing about.
  TodoUpdated = Data.define(:todos)
  VisitorAway = Data.define(:since)
  CheckoutClosed = Data.define(:total)
end

# A host that has a state vocabulary of its own, overriding the public
# {#custom_name} hook — no private method reached into.
class ChatEmitter < Ask::AGUI::Emitter
  NAMES = { "VisitorAway" => "resting" }

  def custom_name(event)
    NAMES.fetch(event.class.name.split("::").last) { super }
  end
end

# Covers Ask::AGUI::Emitter: every ask-agent → AG-UI mapping, the
# empty-delta rules, the CUSTOM passthrough, and the run envelope. Every
# emitted frame is parsed and validated against the protocol JSON Schema,
# so hand-rolled JSON can never sneak onto the wire.
class EmitterTest < Minitest::Test
  SCHEMA_PATH = AG_UI_SCHEMA_PATH

  def schema
    @schema ||= JSON.parse(File.read(SCHEMA_PATH))
  end

  def schemer_for(definition)
    @schemers ||= {}
    @schemers[definition] ||= JSONSchemer.schema(schema.merge("$ref" => "#/definitions/#{definition}"))
  end

  # Asserts SSE framing, parses the payload, and validates it against the
  # schema definition for its type. Answers the payload.
  def assert_valid_frame(frame)
    assert_match(/\Adata: \{.*\}\n\n\z/m, frame, "frame must be one `data: <json>` line plus a blank line")
    payload = JSON.parse(frame.sub(/\Adata: /, ""))
    definition = "#{payload.fetch("type").split("_").map(&:capitalize).join}Event"
    assert schema["definitions"].key?(definition), "no schema definition for #{payload["type"]}"
    errors = schemer_for(definition).validate(payload).to_a
    assert errors.empty?, "#{payload["type"]} failed schema: #{errors.first&.fetch("error")}"
    payload
  end

  # Handles one event and validates every frame it returns.
  def drive(emitter, event)
    emitter.handle(event).map { |frame| assert_valid_frame(frame) }
  end

  def new_emitter(**kwargs)
    Ask::AGUI::Emitter.new(thread_id: "thread-1", run_id: "run-1", **kwargs)
  end

  def test_turn_start_opens_the_run
    payloads = drive(new_emitter, AgentEvents::TurnStart.new)

    assert_equal ["RUN_STARTED"], payloads.map { |p| p["type"] }
    assert_equal "thread-1", payloads.first["threadId"]
    assert_equal "run-1", payloads.first["runId"]
  end

  def test_run_started_carries_the_input_messages
    messages = [AgUiProtocol::Core::Types::UserMessage.new(id: "u1", content: "Hello")]
    payloads = drive(new_emitter(messages: messages), AgentEvents::TurnStart.new)

    input = payloads.first["input"]
    assert_equal "thread-1", input["threadId"]
    assert_equal [{ "id" => "u1", "role" => "user", "content" => "Hello" }], input["messages"]
  end

  def test_start_is_idempotent
    emitter = new_emitter

    assert_equal 1, drive(emitter, AgentEvents::TurnStart.new).size
    assert_equal [], emitter.handle(AgentEvents::TurnStart.new)
  end

  def test_text_deltas_become_start_content_end
    emitter = new_emitter
    drive(emitter, AgentEvents::TurnStart.new)

    started = drive(emitter, AgentEvents::TextDelta.new(content: "Hel"))
    continued = drive(emitter, AgentEvents::TextDelta.new(content: "lo"))
    ended = drive(emitter, AgentEvents::MessageEnd.new(tool_calls: false))

    assert_equal ["TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT"], started.map { |p| p["type"] }
    assert_equal ["TEXT_MESSAGE_CONTENT"], continued.map { |p| p["type"] }
    assert_equal ["TEXT_MESSAGE_END"], ended.map { |p| p["type"] }

    message_id = started.first["messageId"]
    [started, continued, ended].flatten.each { |p| assert_equal message_id, p["messageId"] }
    assert_equal "Hel", started.last["delta"]
    assert_equal "assistant", started.first["role"]
  end

  def test_text_drops_only_empty_deltas
    emitter = new_emitter
    drive(emitter, AgentEvents::TurnStart.new)

    assert_equal [], drive(emitter, AgentEvents::TextDelta.new(content: ""))
    assert_equal [], drive(emitter, AgentEvents::TextDelta.new(content: nil))

    # Nothing opened, so there is nothing to close either.
    assert_equal [], drive(emitter, AgentEvents::MessageEnd.new(tool_calls: false))

    # A single space is content: it is emitted in order, so the joined
    # text keeps the space ("due 45 days", never "due45 days").
    first = drive(emitter, AgentEvents::TextDelta.new(content: "due"))
    space = drive(emitter, AgentEvents::TextDelta.new(content: " "))
    last = drive(emitter, AgentEvents::TextDelta.new(content: "45 days"))

    assert_equal ["TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT"], first.map { |p| p["type"] }
    assert_equal ["TEXT_MESSAGE_CONTENT"], space.map { |p| p["type"] }
    assert_equal " ", space.first["delta"]
    assert_equal ["TEXT_MESSAGE_CONTENT"], last.map { |p| p["type"] }
    assert_equal "due 45 days", (first + space + last).select { |p| p["type"] == "TEXT_MESSAGE_CONTENT" }.map { |p| p["delta"] }.join
  end

  def test_text_stream_opens_the_run_when_turn_start_was_skipped
    payloads = drive(new_emitter, AgentEvents::TextDelta.new(content: "Hi"))

    assert_equal ["RUN_STARTED", "TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT"], payloads.map { |p| p["type"] }
  end

  def test_reasoning_deltas_become_the_reasoning_chain
    emitter = new_emitter
    drive(emitter, AgentEvents::TurnStart.new)

    opened = drive(emitter, AgentEvents::ThinkingDelta.new(content: "let me think"))
    assert_equal ["REASONING_START", "REASONING_MESSAGE_START", "REASONING_MESSAGE_CONTENT"],
      opened.map { |p| p["type"] }
    assert_equal "reasoning", opened[1]["role"]

    message_id = opened.first["messageId"]
    opened.each { |p| assert_equal message_id, p["messageId"] }

    closed = drive(emitter, AgentEvents::MessageEnd.new(tool_calls: false))
    assert_equal ["REASONING_MESSAGE_END", "REASONING_END"], closed.map { |p| p["type"] }
    closed.each { |p| assert_equal message_id, p["messageId"] }
  end

  def test_reasoning_drops_empty_deltas
    emitter = new_emitter
    drive(emitter, AgentEvents::TurnStart.new)

    assert_equal [], drive(emitter, AgentEvents::ThinkingDelta.new(content: ""))
    assert_equal [], drive(emitter, AgentEvents::ThinkingDelta.new(content: nil))
    assert_equal [], drive(emitter, AgentEvents::MessageEnd.new(tool_calls: false))
  end

  def test_tool_call_delta_becomes_start_args_end_result
    emitter = new_emitter
    drive(emitter, AgentEvents::TurnStart.new)

    first = drive(emitter, AgentEvents::ToolCallDelta.new(name: "search", arguments: '{"q":"AG-UI"}', id: "tc-1"))
    assert_equal ["TOOL_CALL_START", "TOOL_CALL_ARGS"], first.map { |p| p["type"] }
    assert_equal "tc-1", first.first["toolCallId"]
    assert_equal "search", first.first["toolCallName"]
    assert_equal '{"q":"AG-UI"}', first.last["delta"]

    # A repeated delta for the same call appends args without reopening it.
    second = drive(emitter, AgentEvents::ToolCallDelta.new(name: "search", arguments: '{"page":2}', id: "tc-1"))
    assert_equal ["TOOL_CALL_ARGS"], second.map { |p| p["type"] }

    closed = drive(emitter, AgentEvents::MessageEnd.new(tool_calls: true))
    assert_equal ["TOOL_CALL_END"], closed.map { |p| p["type"] }

    result = drive(
      emitter,
      AgentEvents::ToolExecutionEnd.new(
        name: "search", id: "tc-1",
        result: { message: "found it", status: "success" }, is_error: false, duration_ms: 12
      )
    )
    assert_equal ["TOOL_CALL_RESULT"], result.map { |p| p["type"] }
    assert_equal "tc-1", result.first["toolCallId"]
    assert_equal "found it", result.first["content"]
    assert_equal "tool", result.first["role"]
  end

  def test_tool_call_drops_empty_args_deltas
    emitter = new_emitter
    drive(emitter, AgentEvents::TurnStart.new)

    opened = drive(emitter, AgentEvents::ToolCallDelta.new(name: "search", arguments: "", id: "tc-1"))
    assert_equal ["TOOL_CALL_START"], opened.map { |p| p["type"] }
    assert_equal [], drive(emitter, AgentEvents::ToolCallDelta.new(name: "search", arguments: nil, id: "tc-1"))
  end

  def test_tool_call_args_accepts_a_hash
    emitter = new_emitter
    drive(emitter, AgentEvents::TurnStart.new)

    payloads = drive(emitter, AgentEvents::ToolCallDelta.new(name: "search", arguments: { "q" => "AG-UI" }, id: "tc-1"))
    assert_equal ["TOOL_CALL_START", "TOOL_CALL_ARGS"], payloads.map { |p| p["type"] }
    assert_equal '{"q":"AG-UI"}', payloads.last["delta"]
  end

  def test_tool_execution_start_opens_calls_the_stream_never_announced
    emitter = new_emitter
    drive(emitter, AgentEvents::TurnStart.new)

    payloads = drive(emitter, AgentEvents::ToolExecutionStart.new(name: "search", arguments: { "q" => "x" }, id: "tc-9"))
    assert_equal ["TOOL_CALL_START", "TOOL_CALL_ARGS"], payloads.map { |p| p["type"] }
    assert_equal "tc-9", payloads.first["toolCallId"]
  end

  def test_tool_execution_end_alone_still_brackets_the_call
    emitter = new_emitter
    drive(emitter, AgentEvents::TurnStart.new)

    payloads = drive(
      emitter,
      AgentEvents::ToolExecutionEnd.new(
        name: "search", id: "tc-9", result: "done", is_error: false, duration_ms: 3
      )
    )
    assert_equal ["TOOL_CALL_START", "TOOL_CALL_END", "TOOL_CALL_RESULT"], payloads.map { |p| p["type"] }
    assert_equal "done", payloads.last["content"]
  end

  def test_session_end_finishes_the_run
    emitter = new_emitter
    drive(emitter, AgentEvents::TurnStart.new)

    finished = drive(
      emitter,
      AgentEvents::SessionEnd.new(
        result: "done", turn_count: 1, tool_calls_made: 0,
        input_tokens: 1, output_tokens: 1, cost: 0.0
      )
    )
    assert_equal ["RUN_FINISHED"], finished.map { |p| p["type"] }
    assert_equal "thread-1", finished.first["threadId"]
    assert_equal "run-1", finished.first["runId"]

    # The run stays shut.
    assert_equal [], emitter.handle(
      AgentEvents::SessionEnd.new(
        result: "done", turn_count: 1, tool_calls_made: 0,
        input_tokens: 1, output_tokens: 1, cost: 0.0
      )
    )
  end

  def test_turn_end_closes_messages_but_keeps_the_run_open
    emitter = new_emitter
    drive(emitter, AgentEvents::TurnStart.new)
    drive(emitter, AgentEvents::TextDelta.new(content: "part one"))

    closed = drive(
      emitter,
      AgentEvents::TurnEnd.new(tool_results: [], turn_number: 1, input_tokens: 1, output_tokens: 1, cost: 0.0)
    )
    assert_equal ["TEXT_MESSAGE_END"], closed.map { |p| p["type"] }

    # The next turn streams on under the same run.
    continued = drive(emitter, AgentEvents::TextDelta.new(content: "part two"))
    assert_equal ["TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT"], continued.map { |p| p["type"] }
  end

  def test_finish_closes_open_messages_then_finishes
    emitter = new_emitter
    drive(emitter, AgentEvents::TurnStart.new)
    drive(emitter, AgentEvents::TextDelta.new(content: "Hi"))

    payloads = emitter.finish.map { |frame| assert_valid_frame(frame) }
    assert_equal ["TEXT_MESSAGE_END", "RUN_FINISHED"], payloads.map { |p| p["type"] }
    assert_equal [], emitter.finish
  end

  def test_error_event_becomes_run_error
    emitter = new_emitter
    drive(emitter, AgentEvents::TurnStart.new)

    payloads = drive(emitter, AgentEvents::Error.new(error: "boom", recoverable: false))
    assert_equal ["RUN_ERROR"], payloads.map { |p| p["type"] }
    assert_equal "boom", payloads.first["message"]
  end

  def test_fail_accepts_exceptions_and_strings
    emitter = new_emitter
    drive(emitter, AgentEvents::TurnStart.new)

    payloads = emitter.fail(RuntimeError.new("kaput")).map { |frame| assert_valid_frame(frame) }
    assert_equal ["RUN_ERROR"], payloads.map { |p| p["type"] }
    assert_equal "kaput", payloads.first["message"]

    emitter = new_emitter
    drive(emitter, AgentEvents::TurnStart.new)
    payloads = emitter.fail("plain failure").map { |frame| assert_valid_frame(frame) }
    assert_equal "plain failure", payloads.first["message"]
  end

  def test_unknown_events_ride_the_custom_passthrough
    emitter = new_emitter
    drive(emitter, AgentEvents::TurnStart.new)

    payloads = drive(emitter, AgentEvents::TodoUpdated.new(todos: [{ "id" => "1", "content" => "write it" }]))
    assert_equal ["CUSTOM"], payloads.map { |p| p["type"] }
    assert_equal "TodoUpdated", payloads.first["name"]
    assert_equal({ "todos" => [{ "id" => "1", "content" => "write it" }] }, payloads.first["value"])
  end

  def test_custom_names_rename_the_kinds_the_host_named
    emitter = new_emitter(custom_names: { VisitorAway: :resting, "CheckoutClosed" => "visitor_spent" })
    drive(emitter, AgentEvents::TurnStart.new)

    away = drive(emitter, AgentEvents::VisitorAway.new(since: 12))
    assert_equal ["CUSTOM"], away.map { |p| p["type"] }
    assert_equal "resting", away.first["name"]
    assert_equal({ "since" => 12 }, away.first["value"])

    closed = drive(emitter, AgentEvents::CheckoutClosed.new(total: 42.0))
    assert_equal "visitor_spent", closed.first["name"]
    assert_equal({ "total" => 42.0 }, closed.first["value"])
  end

  def test_events_the_host_did_not_name_keep_the_default_custom_name
    emitter = new_emitter(custom_names: { "VisitorAway" => "resting" })
    drive(emitter, AgentEvents::TurnStart.new)

    payloads = drive(emitter, AgentEvents::TodoUpdated.new(todos: []))
    assert_equal ["CUSTOM"], payloads.map { |p| p["type"] }
    assert_equal "TodoUpdated", payloads.first["name"]

    # A name that carries nothing is no name: it falls back like any
    # other unnamed kind rather than putting "" on the wire.
    blank = new_emitter(custom_names: { "VisitorAway" => "" })
    drive(blank, AgentEvents::TurnStart.new)
    assert_equal "VisitorAway", drive(blank, AgentEvents::VisitorAway.new(since: 1)).first["name"]
  end

  def test_custom_name_is_a_public_hook_a_host_can_override
    emitter = ChatEmitter.new(thread_id: "thread-1", run_id: "run-1")
    drive(emitter, AgentEvents::TurnStart.new)

    named = drive(emitter, AgentEvents::VisitorAway.new(since: 3))
    assert_equal "resting", named.first["name"]

    # The override falls through to the gem's default for anything else.
    unnamed = drive(emitter, AgentEvents::CheckoutClosed.new(total: 7.0))
    assert_equal "CheckoutClosed", unnamed.first["name"]

    assert_respond_to emitter, :custom_name
  end

  def test_custom_naming_never_moves_the_event_mapping
    emitter = ChatEmitter.new(thread_id: "thread-1", run_id: "run-1")
    payloads = []
    payloads += drive(emitter, AgentEvents::TurnStart.new)
    payloads += drive(emitter, AgentEvents::TextDelta.new(content: "Hi"))
    payloads += drive(emitter, AgentEvents::VisitorAway.new(since: 1))
    payloads += drive(emitter, AgentEvents::MessageEnd.new(tool_calls: false))

    assert_equal [
      "RUN_STARTED",
      "TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT",
      "CUSTOM",
      "TEXT_MESSAGE_END"
    ], payloads.map { |p| p["type"] }
    assert_equal "resting", payloads[3]["name"]
  end

  def test_full_turn_end_to_end
    emitter = new_emitter
    payloads = []
    payloads += drive(emitter, AgentEvents::TurnStart.new)
    payloads += drive(emitter, AgentEvents::TextDelta.new(content: "Checking "))
    payloads += drive(emitter, AgentEvents::ThinkingDelta.new(content: "which tool?"))
    payloads += drive(emitter, AgentEvents::TextDelta.new(content: "now."))
    payloads += drive(emitter, AgentEvents::ToolCallDelta.new(name: "search", arguments: '{"q":"x"}', id: "tc-1"))
    payloads += drive(emitter, AgentEvents::MessageEnd.new(tool_calls: true))
    payloads += drive(
      emitter,
      AgentEvents::ToolExecutionEnd.new(
        name: "search", id: "tc-1",
        result: { message: "hit", status: "success" }, is_error: false, duration_ms: 5
      )
    )
    payloads += drive(
      emitter,
      AgentEvents::SessionEnd.new(
        result: "hit", turn_count: 1, tool_calls_made: 1,
        input_tokens: 10, output_tokens: 5, cost: 0.001
      )
    )

    assert_equal [
      "RUN_STARTED",
      "TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT",
      "REASONING_START", "REASONING_MESSAGE_START", "REASONING_MESSAGE_CONTENT",
      "TEXT_MESSAGE_CONTENT",
      "TOOL_CALL_START", "TOOL_CALL_ARGS",
      "REASONING_MESSAGE_END", "REASONING_END",
      "TEXT_MESSAGE_END", "TOOL_CALL_END",
      "TOOL_CALL_RESULT",
      "RUN_FINISHED"
    ], payloads.map { |p| p["type"] }
  end
end
