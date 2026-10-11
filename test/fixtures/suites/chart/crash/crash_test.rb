# frozen_string_literal: true

require_relative '../test/test_helper'

# Kills its own process: a cell, or the worker running it.
class CrashTest < Minitest::Test
  def test_crash
    Process.kill(:KILL, Process.pid)
  end
end
