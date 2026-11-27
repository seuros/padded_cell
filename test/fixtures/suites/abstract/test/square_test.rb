# frozen_string_literal: true

require_relative 'support/shape_test_case'

class SquareTest < ShapeTestCase
  def shape = { area: 4 }
end

# Declared in a test file, after its tests.
class PolygonTest < ShapeTestCase
  def test_has_sides
    assert_operator shape.fetch(:sides), :>=, 3
  end

  abstract_test_case!
end

class TriangleTest < PolygonTest
  def shape = { area: 6, sides: 3 }
end
