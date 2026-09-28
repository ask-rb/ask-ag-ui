# ask-ag-ui

[![Gem Version](https://badge.fury.io/rb/ask-ag-ui.svg)](https://badge.fury.io/rb/ask-ag-ui)

The AG-UI (Agent-User Interaction) protocol server for the ask-rb ecosystem — SSE event streaming and the runtime surface that assistant-ui and CopilotKit frontends expect.

## Installation

```ruby
gem "ask-ag-ui"
```

## Quick Start

```ruby
require "ask-ag-ui"

Ask::AGUI::VERSION  # => "0.1.0"
```

## The seam: `Ask::AGUI::Emitter`

The emitter turns ask-rb agent/session events into AG-UI protocol frames.
A transport drives one emitter per run: it hands over the AG-UI run context,
feeds it agent events, and writes the SSE frames it answers to the stream.
The transport owns the socket — the emitter only translates and encodes.

```ruby
require "ask-ag-ui"

messages = [AgUiProtocol::Core::Types::UserMessage.new(id: "u1", content: "Hi")]
emitter = Ask::AGUI::Emitter.new(thread_id: "t1", run_id: "r1", messages: messages)

emitter.handle(turn_start_event).each { |frame| stream.write(frame) }
# => ["data: {\"type\":\"RUN_STARTED\",...}\n\n", ...]

emitter.finish.each { |frame| stream.write(frame) }
# => ["data: {\"type\":\"RUN_FINISHED\",...}\n\n"]
```

The vocabulary, matched by class name so the emitter never depends on
ask-agent internals:

| Agent event | AG-UI events |
|---|---|
| `TurnStart` | `RUN_STARTED` |
| `TextDelta` | `TEXT_MESSAGE_START` → `TEXT_MESSAGE_CONTENT` → `TEXT_MESSAGE_END` (only empty deltas dropped — a space is content) |
| `ThinkingDelta` | `REASONING_START` → `REASONING_MESSAGE_START` → `REASONING_MESSAGE_CONTENT` → `REASONING_MESSAGE_END` → `REASONING_END` (empty deltas dropped) |
| `ToolCallDelta`, `ToolExecutionStart`, `ToolExecutionEnd` | `TOOL_CALL_START` → `TOOL_CALL_ARGS` → `TOOL_CALL_END` → `TOOL_CALL_RESULT` (empty args deltas dropped) |
| `SessionEnd` / `#finish` | `RUN_FINISHED` |
| `Error` / `#fail` | `RUN_ERROR` |
| anything else | one generic `CUSTOM` passthrough (`name` + `value`) |

Every frame is built with `AgUiProtocol::Core::Events::*` and encoded with
`AgUiProtocol::Encoder::EventEncoder` — event JSON is never hand-rolled.

## Mounting: `Ask::AGUI::Server`

The server is the conventional Rack surface AG-UI clients expect. The host
owns the agent and answers agent events; the gem owns the socket, the
framing, and one `Emitter` per run. Plain Rack 3 with an enumerable body —
it runs under any Rack server, with no Rails, ask-agent, or async
dependency.

```ruby
require "ask-ag-ui"

app = Ask::AGUI::Server.new(agent_id: "default") do |run|
  # run.thread_id, run.run_id, run.messages, run.tools,
  # run.context, run.forwarded_props — answer agent events:
  [TurnStart.new, TextDelta.new(content: "Hello")]
end
```

Rackup:

```ruby
# config.ru
require "ask-ag-ui"

run Ask::AGUI::Server.new(agent_id: "default") { |run| MyAgent.events_for(run) }
```

Rails:

```ruby
# config/routes.rb
mount Ask::AGUI::Server.new(agent_id: "default") { |run| MyAgent.events_for(run) },
  at: "/api/copilotkit"
```

Routes: `GET /info`, `POST /agent/:id/run` (SSE), `POST /agent/:id/connect`
(replays recorded frames, or an immediately-completed empty stream when
there is nothing to replay), `POST /agent/:id/stop/:thread_id` (JSON ack).
Malformed run input answers `400` with a JSON error body.

One curl example (run a thread through the stub above):

```
curl -N -X POST http://localhost:9292/agent/default/run \
  -H 'Content-Type: application/json' \
  -d '{"threadId":"t1","runId":"r1","messages":[{"id":"u1","role":"user","content":"Hi"}],"tools":[],"context":[]}'
```

The in-memory run store keeps frames in this process only — replay and
stop need a shared store once you run more than one process.

## Development

```
bundle install
bundle exec rake test
```

The suite validates every emitted SSE frame against the AG-UI protocol's
canonical JSON Schema, vendored at `test/fixtures/ag_ui.json` (generated
from the reference Python SDK; the copy came from the reference
implementation's `data/ag_ui.json`). See `test/fixtures/README.md` for
provenance and refresh instructions. The fixture resolves through a
repo-relative path, so a fresh clone needs nothing outside the repo — and
a missing fixture fails loudly (`ENOENT`) rather than skipping validation.

## License

MIT
