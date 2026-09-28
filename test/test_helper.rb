# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    add_filter "/test/"
    add_filter "/vendor/"
    track_files "lib/**/*.rb"
  end
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "ask-ag-ui"

require "minitest/autorun"
require "mocha/minitest"

# The vendored AG-UI protocol JSON Schema the suite validates emitted
# frames against — see test/fixtures/README.md for provenance. Resolved
# inside the repo so the suite runs from a fresh clone with nothing
# outside it. Read eagerly: a missing fixture raises ENOENT and errors
# the suite rather than skipping validation.
AG_UI_SCHEMA_PATH = File.expand_path("fixtures/ag_ui.json", __dir__)
