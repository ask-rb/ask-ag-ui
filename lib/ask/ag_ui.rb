# frozen_string_literal: true

require_relative "ag_ui/version"
require_relative "ag_ui/emitter"
require_relative "ag_ui/run_store"
require_relative "ag_ui/run"
require_relative "ag_ui/server"

# Namespace for the AG-UI (Agent-User Interaction) protocol server.
#
# ask-ag-ui is the runtime surface that assistant-ui and CopilotKit
# frontends expect: SSE event streaming over the AG-UI protocol, backed by
# the ask-rb ecosystem.
#
# The public seam is Ask::AGUI::Emitter — see that class for the contract.
module Ask
  # AG-UI protocol surface for ask-rb.
  module AGUI
  end
end
