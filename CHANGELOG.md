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
