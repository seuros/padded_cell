# frozen_string_literal: true

require 'minitest/autorun'

class SlowTest < Minitest::Test
  8.times do |i|
    define_method(:"test_#{i}") { sleep 0.4 }
  end
end
