# frozen_string_literal: true

require 'minitest/autorun'

# Lives outside the discovered *_test.rb files, as shared bases do: only
# its subclasses run its tests.
class ShapeTestCase < Minitest::Test
  abstract_test_case!

  def test_area_is_positive
    assert_operator shape.fetch(:area), :>, 0
  end
end
