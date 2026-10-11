# frozen_string_literal: true

require_relative 'test_helper'

class LazyTest < Minitest::Test
  def test_early
    assert_equal :early, Lazy.call(true)
  end
end
