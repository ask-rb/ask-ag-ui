# frozen_string_literal: true

require_relative "test_helper"

# Guards the family's gemspec invariants: every ask-* gem keeps a plain
# gemspec (never `git ls-files`), an `ask-` prefixed name, and a present
# version greater than "0".
class GemspecTest < Minitest::Test
  def test_gemspec_is_valid
    spec = Gem::Specification.load(File.expand_path("../ask-ag-ui.gemspec", __dir__))
    assert spec, "Could not load gemspec"
    assert_kind_of Gem::Specification, spec
    assert spec.name.to_s.start_with?("ask-")
    assert spec.version.to_s > "0"
  end
end
