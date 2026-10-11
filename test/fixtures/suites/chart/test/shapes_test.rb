# frozen_string_literal: true

require_relative 'test_helper'

class ShapesTest < Minitest::Test
  def test_area
    assert_equal 4, Square.new(2).area
  end

  def test_hello
    assert_equal :hello, GREETER.new.hello
  end

  def test_directives
    assert_equal :no, Directives.call(false)
  end
end
