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
