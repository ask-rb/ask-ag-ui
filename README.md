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
| `TextDelta` | `TEXT_MESSAGE_START` → `TEXT_MESSAGE_CONTENT` → `TEXT_MESSAGE_END` (empty/blank deltas dropped) |
| `ThinkingDelta` | `REASONING_START` → `REASONING_MESSAGE_START` → `REASONING_MESSAGE_CONTENT` → `REASONING_MESSAGE_END` → `REASONING_END` (empty deltas dropped) |
| `ToolCallDelta`, `ToolExecutionStart`, `ToolExecutionEnd` | `TOOL_CALL_START` → `TOOL_CALL_ARGS` → `TOOL_CALL_END` → `TOOL_CALL_RESULT` (empty args deltas dropped) |
| `SessionEnd` / `#finish` | `RUN_FINISHED` |
| `Error` / `#fail` | `RUN_ERROR` |
| anything else | one generic `CUSTOM` passthrough (`name` + `value`) |

Every frame is built with `AgUiProtocol::Core::Events::*` and encoded with
`AgUiProtocol::Encoder::EventEncoder` — event JSON is never hand-rolled.

## Development

```
bundle install
bundle exec rake test
```

## License

MIT
