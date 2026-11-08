# frozen_string_literal: true

require_relative 'test_helper'
require 'padded_cell/limits'
require 'padded_cell/asylum'

class LimitsTest < Minitest::Test
  NS = PaddedCell::Limits::NS

  def test_no_limits_never_expire
    limits = PaddedCell::Limits.new

    assert_nil limits.for_test(0).expires_at
    refute limits.spent?(2**62)
  end

  def test_a_test_deadline_is_its_timeout
    limits = PaddedCell::Limits.new(timeout: 2.5, started: 0)

    assert_equal 10 * NS + (2.5 * NS), limits.for_test(10 * NS).expires_at
    assert_equal 'timed out after 2.5s', limits.message(limits.for_test(0))
  end

  def test_a_test_never_outlives_the_budget
    limits = PaddedCell::Limits.new(timeout: 5, budget: 10.0, started: 0)

    assert_equal 5 * NS, limits.for_test(0).expires_at
    assert_equal 10 * NS, limits.for_test(8 * NS).expires_at
    assert_equal 'run budget of 10.0s spent', limits.message(limits.for_test(8 * NS))
    refute limits.spent?((10 * NS) - 1)
    assert limits.spent?(10 * NS)
  end

  def test_remaining_seconds
    deadline = PaddedCellNative::Deadline.after(0, 3 * NS)

    assert_in_delta 2.0, PaddedCell::Limits.remaining(deadline, NS)
    assert_in_delta 0.0, PaddedCell::Limits.remaining(deadline, 4 * NS)
    assert_nil PaddedCell::Limits.remaining(PaddedCellNative::Deadline.never, 0)
  end

  def test_restarts_give_up_past_their_limit
    restarts = PaddedCellNative::Restarts.new(2)

    assert_equal 16, restarts.limit
    assert(16.times.all? { restarts.died(it) })
    refute restarts.died(16)
  end

  # --seed takes 64 bits: retry seeds keep them apart instead of folding
  # them onto 16.
  def test_retry_seeds_keep_64_bits
    seeds = [2**40, 2**40 + 0xffff].map { PaddedCell::Asylum.retry_seed(it, 2) }

    assert_equal 2, seeds.uniq.size
    assert_equal (2**40) + (2 * 0x9e37), seeds.first
    assert_equal 1, PaddedCell::Asylum.retry_seed(2**64 - (2 * 0x9e37) + 1, 2)
    assert_equal 7, PaddedCell::Asylum.retry_seed(7, 1)
  end
end
