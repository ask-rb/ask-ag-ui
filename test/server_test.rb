# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "stringio"
require "json_schemer"

# Duck-typed stand-ins for the ask-agent event vocabulary. The server must
# never require ask-agent — it drives the emitter with these by class name
# and shape, exactly like a host application would.
module ServerAgentEvents
  TextDelta = Data.define(:content)
  TurnStart = Data.define
end

# Covers Ask::AGUI::Server at Rack level: the app is called directly with
# env hashes (no server process). The stub run's frames are validated
# against the protocol JSON Schema, so hand-rolled JSON can never sneak
# onto the wire.
class ServerTest < Minitest::Test
  SCHEMA_PATH = ENV.fetch("AG_UI_SCHEMA_PATH", "/Users/kaka/Code/ask-rb/refs/ag-ui/data/ag_ui.json")

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

  def minimal_body(thread_id: "t1", run_id: "r1")
    JSON.generate({
      "threadId" => thread_id, "runId" => run_id, "state" => nil,
      "messages" => [{ "id" => "u1", "role" => "user", "content" => "Hi" }],
      "tools" => [], "context" => [], "forwardedProps" => nil
    })
  end

  def stub_app(**kwargs, &block)
    handler = block || ->(_run) { [ServerAgentEvents::TurnStart.new, ServerAgentEvents::TextDelta.new(content: "Hello")] }
    Ask::AGUI::Server.new(agent_id: "default", **kwargs, &handler)
  end

  def call(app, method, path, body: "")
    app.call({
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "rack.input" => StringIO.new(body)
    })
  end

  def collect_frames(body)
    frames = []
    body.each { |chunk| frames << chunk }
    frames
  end

  def test_requires_a_run_handler_block
    assert_raises(ArgumentError) { Ask::AGUI::Server.new }
  end

  def test_info_names_the_agent_its_class_the_mode_and_protocol_capabilities
    status, headers, body = call(stub_app, "GET", "/info")

    assert_equal 200, status
    assert_equal "application/json", headers["content-type"]

    payload = JSON.parse(body.first)
    agent = payload.fetch("agents").fetch("default")
    assert_equal "default", agent["name"]
    assert_equal "BuiltInAgent", agent["className"]

    assert_equal "sse", payload["mode"]
    assert_equal Ask::AGUI::VERSION, payload["version"]

    capabilities = agent.fetch("capabilities")
    assert_equal true, capabilities.fetch("transport").fetch("streaming")
    assert_equal "default", capabilities.fetch("identity").fetch("name")
  end

  def test_info_capabilities_come_from_the_protocol_models
    capabilities = AgUiProtocol::Core::Capabilities::AgentCapabilities.new(
      identity: AgUiProtocol::Core::Capabilities::IdentityCapabilities.new(name: "default"),
      transport: AgUiProtocol::Core::Capabilities::TransportCapabilities.new(streaming: true)
    )
    status, _, body = call(stub_app(capabilities: capabilities), "GET", "/info")

    assert_equal 200, status
    agent = JSON.parse(body.first).fetch("agents").fetch("default")
    assert_equal capabilities.as_json, agent["capabilities"]
  end

  def test_run_streams_the_stub_run_as_schema_valid_sse
    status, headers, body = call(stub_app, "POST", "/agent/default/run", body: minimal_body)

    assert_equal 200, status
    assert_equal "text/event-stream", headers["content-type"]

    payloads = collect_frames(body).map { |frame| assert_valid_frame(frame) }
    assert_equal %w[RUN_STARTED TEXT_MESSAGE_START TEXT_MESSAGE_CONTENT TEXT_MESSAGE_END RUN_FINISHED],
      payloads.map { |p| p["type"] }

    assert_equal "t1", payloads.first["threadId"]
    assert_equal "r1", payloads.first["runId"]
    assert_equal "Hello", payloads.find { |p| p["type"] == "TEXT_MESSAGE_CONTENT" }["delta"]
  end

  def test_run_hands_the_host_the_parsed_input
    seen = nil
    app = stub_app do |run|
      seen = run
      []
    end
    call(app, "POST", "/agent/default/run", body: minimal_body).last.each { |_| nil }

    assert_equal "default", seen.agent_id
    assert_equal "t1", seen.thread_id
    assert_equal "r1", seen.run_id
    assert_equal 1, seen.messages.size
    assert_equal "u1", seen.messages.first.id
  end

  def test_run_rejects_malformed_input_with_400_json
    status, headers, body = call(stub_app, "POST", "/agent/default/run", body: "{}")

    assert_equal 400, status
    assert_equal "application/json", headers["content-type"]

    payload = JSON.parse(body.first)
    assert_equal "Invalid request body", payload["error"]
    assert payload["details"].to_s.include?("threadId")
  end

  def test_run_rejects_non_json_with_400_json
    status, _, body = call(stub_app, "POST", "/agent/default/run", body: "{nope")

    assert_equal 400, status
    assert_equal "Invalid request body", JSON.parse(body.first)["error"]
  end

  def test_run_errors_become_run_error_frames_not_500s
    app = stub_app { |_run| raise "boom" }
    status, _, body = call(app, "POST", "/agent/default/run", body: minimal_body)

    assert_equal 200, status
    payloads = collect_frames(body).map { |frame| assert_valid_frame(frame) }
    assert_equal %w[RUN_STARTED RUN_ERROR], payloads.map { |p| p["type"] }
    assert_equal "boom", payloads.last["message"]
  end

  def test_connect_completes_immediately_when_nothing_was_recorded
    status, headers, body = call(stub_app, "POST", "/agent/default/connect", body: "")

    assert_equal 200, status
    assert_equal "text/event-stream", headers["content-type"]
    assert_equal [], collect_frames(body)
  end

  def test_connect_replays_the_recorded_run
    app = stub_app
    _, _, run_body = call(app, "POST", "/agent/default/run", body: minimal_body)
    collect_frames(run_body)

    status, headers, body = call(app, "POST", "/agent/default/connect", body: minimal_body)

    assert_equal 200, status
    assert_equal "text/event-stream", headers["content-type"]

    payloads = collect_frames(body).map { |frame| assert_valid_frame(frame) }
    assert_equal %w[RUN_STARTED TEXT_MESSAGE_START TEXT_MESSAGE_CONTENT TEXT_MESSAGE_END RUN_FINISHED],
      payloads.map { |p| p["type"] }
    assert_equal "Hello", payloads.find { |p| p["type"] == "TEXT_MESSAGE_CONTENT" }["delta"]
  end

  def test_connect_for_an_unknown_thread_replays_nothing
    app = stub_app
    _, _, run_body = call(app, "POST", "/agent/default/run", body: minimal_body)
    collect_frames(run_body)

    _, _, body = call(app, "POST", "/agent/default/connect", body: minimal_body(thread_id: "other"))
    assert_equal [], collect_frames(body)
  end

  def test_stop_acknowledges_as_json
    status, headers, body = call(stub_app, "POST", "/agent/default/stop/t1", body: "")

    assert_equal 200, status
    assert_equal "application/json", headers["content-type"]
    assert_equal({ "stopped" => true }, JSON.parse(body.first))
  end

  def test_unknown_routes_answer_404_json
    status, _, body = call(stub_app, "GET", "/nope")

    assert_equal 404, status
    assert_equal "Not found", JSON.parse(body.first)["error"]
  end

  def test_routes_match_under_a_mount_prefix
    status, _, body = call(stub_app, "GET", "/api/copilotkit/info")
    assert_equal 200, status
    assert JSON.parse(body.first)["agents"].key?("default")

    status, _, run_body = call(stub_app, "POST", "/api/copilotkit/agent/default/run", body: minimal_body)
    assert_equal 200, status
    assert_equal "RUN_STARTED", assert_valid_frame(collect_frames(run_body).first)["type"]
  end
end
