# frozen_string_literal: true

require_relative 'test_helper'

# Fails its first attempt: with --asylum its retry passes, and what the retry
# runs is not counted.
class FlakyTest < Minitest::Test
  def test_passes_when_retried
    marker = File.join(ENV.fetch('FLAKY_DIR'), 'retried')
    if File.exist?(marker)
      assert_equal :no, Calc.new.maybe(false)
    else
      File.write(marker, '')
      flunk 'lost the race'
    end
  end
end
