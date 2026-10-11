# frozen_string_literal: true

require_relative 'test_helper'

class CalcTest < Minitest::Test
  def setup
    @calc = Calc.new
  end

  def test_add
    assert_equal 3, @calc.add(1, 2)
  end

  def test_positive
    assert_equal :positive, @calc.sign(2)
  end

  def test_negative
    assert_equal :negative, @calc.sign(-2)
  end

  def test_maybe
    assert_equal :yes, @calc.maybe(true)
  end
end

class SignTest < Minitest::Test
  def test_zero
    assert_equal :zero, Calc.new.sign(0)
  end

  def test_add_again
    assert_equal 0, Calc.new.add(0, 0)
  end
end
