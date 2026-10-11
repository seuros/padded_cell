# frozen_string_literal: true

require_relative '../test/test_helper'

# What SimpleCov.start leaves behind, without SimpleCov.
module SimpleCov
  def self.pid = Process.pid
end

class SimpleCovTest < Minitest::Test
  def test_nothing
    assert true
  end
end
