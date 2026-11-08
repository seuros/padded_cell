# frozen_string_literal: true

require 'minitest/autorun'
require 'padded_cell'

# Every worker dies before running a test: replacing them would only turn
# each test into a crash report.
PaddedCell.after_fork { exit!(7) }

class CrashLoopTest < Minitest::Test
  60.times do |i|
    define_method(:"test_#{i}") { assert true }
  end
end
