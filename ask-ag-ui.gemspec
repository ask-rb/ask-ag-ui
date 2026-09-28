# frozen_string_literal: true

require_relative "lib/ask/ag_ui/version"

Gem::Specification.new do |spec|
  spec.name = "ask-ag-ui"
  spec.version = Ask::AGUI::VERSION
  spec.authors = ["Kaka Ruto"]
  spec.email = ["kaka@myrrlabs.com"]

  spec.summary = "AG-UI protocol server for the ask-rb ecosystem"
  spec.description = "The AG-UI (Agent-User Interaction) protocol server for the ask-rb ecosystem — SSE event streaming and the runtime surface that assistant-ui and CopilotKit frontends expect."
  spec.homepage = "https://github.com/ask-rb/ask-ag-ui"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"

  spec.files = Dir["lib/**/*", "LICENSE", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5.25"
  spec.add_development_dependency "mocha", "~> 3.1"
  spec.add_development_dependency "rake", "~> 13.0"
end
