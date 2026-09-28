# frozen_string_literal: true

require_relative "ag_ui/version"

# Namespace for the AG-UI (Agent-User Interaction) protocol server.
#
# ask-ag-ui is the runtime surface that assistant-ui and CopilotKit
# frontends expect: SSE event streaming over the AG-UI protocol, backed by
# the ask-rb ecosystem. The protocol API is forthcoming — this skeleton
# only declares the namespace and the version.
module Ask
  # AG-UI protocol surface for ask-rb.
  module AGUI
  end
end
