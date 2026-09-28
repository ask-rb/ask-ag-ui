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

The protocol API (events, streaming, agent endpoints) is forthcoming — this
release only establishes the gem skeleton and the `Ask::AGUI` namespace.

## Development

```
bundle install
bundle exec rake test
```

## License

MIT
