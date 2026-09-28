# Changelog

All notable changes to ask-ag-ui are documented here, following
the keep-a-changelog format.

## [Unreleased]

### Added

- `Ask::AGUI::Emitter` — the seam that turns ask-rb agent/session events
  into AG-UI protocol frames. Given the run context (thread id, run id,
  input messages) and a stream of duck-typed agent events, it emits
  `RUN_STARTED`, the text/reasoning/tool-call chains, `RUN_FINISHED` /
  `RUN_ERROR`, and a generic `CUSTOM` passthrough for app-defined events.
  All frames are built with `AgUiProtocol::Core::Events::*` and encoded
  with `AgUiProtocol::Encoder::EventEncoder`. Adds the `ag-ui-protocol`
  runtime dependency.
- `Ask::AGUI::Server` — the mountable Rack surface AG-UI clients expect:
  `GET /info` (agents map with name, class, and capability information
  built from ag-ui-protocol's capability and identity types, plus the
  transport mode), `POST /agent/:id/run` (parses the run input, drives one
  `Emitter` for the run, streams its SSE frames as the host block's agent
  events arrive; malformed input answers 400 JSON),
  `POST /agent/:id/connect` (replays recorded frames, completing
  immediately when there is nothing to replay), and
  `POST /agent/:id/stop/:thread_id` (JSON acknowledgement with cooperative
  cancel). The host supplies the work as a block; the gem owns the socket
  and the framing, with no Rails or ask-agent dependency. Plain Rack 3 and
  plain Ruby — an enumerable body, no async or falcon requirement.
- `Ask::AGUI::Run` — the parsed run input handed to the host block
  (thread id, run id, messages, tools, context, forwarded props, state),
  with best-effort coercion to `AgUiProtocol::Core::Types`.
- `Ask::AGUI::RunStore` — the run-store interface plus the in-memory
  implementation backing replay and stop. In-memory frames live in one
  process only; back replay and stop with a shared store past one process.
