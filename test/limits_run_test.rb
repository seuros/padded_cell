# frozen_string_literal: true

require_relative 'test_helper'

# What bounds a run, end to end: --budget, and workers that keep dying.
class LimitsRunTest < Minitest::Test
  include CLIHelper

  def test_gives_up_on_workers_that_keep_dying
    %w[test worker].each do |isolation|
      run = padded_cell('--no-timings', '-j', '2', '--isolation', isolation, suite: 'crash_loop')
      runs, _assertions, _failures, errors, = run.summary

      assert_equal 1, run.exitstatus, "#{isolation}: #{run.err}"
      assert_equal runs, errors, isolation
      assert_operator runs, :<, 60, isolation
      assert_match(/workers died more than 16 times in 10s; gave up, #{60 - runs} tests not run/, run.err)
    end
  end

  def test_the_budget_cuts_a_test_short
    %w[test worker].each do |isolation|
      started = Minitest.clock_time
      run = padded_cell('--no-timings', '--isolation', isolation, '--budget', '1', '-n', 'test_hangs',
                        suite: 'crashy')

      assert_equal [1, 0, 0, 1, 0], run.summary, isolation
      assert_includes run.out, 'run budget of 1.0s spent', isolation
      assert_operator Minitest.clock_time - started, :<, 10, isolation
    end
  end

  def test_tests_left_out_by_the_budget_fail_the_run
    run = padded_cell('--no-timings', '-j', '1', '--budget', '1', suite: 'slow')
    runs, = run.summary

    assert_equal 1, run.exitstatus
    assert_operator runs, :<, 8
    assert_includes run.err, "run budget of 1.0s spent, #{8 - runs} tests not run"
  end
end
