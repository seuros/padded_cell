# frozen_string_literal: true

require_relative 'test_helper'

class PlanTest < Minitest::Test
  CLASSES = %w[A B A C B A D C].freeze

  # Same input, same expected batches in core/src/plan/tests.rs: the engines
  # agree even where the native extension is not built.
  def test_pinned_order
    durations = [0.5, nil, 0.5, 2.0, nil, 0.1, nil, 0.5]

    assert_equal [[3, 7], [2, 0, 5], [1, 4], [6]], PaddedCell::Scheduler.batches(CLASSES, durations:, seed: 1234)
    assert_equal [[6], [0, 5, 2], [1, 4]], PaddedCell::Scheduler.batches(CLASSES, seed: 1234, shard: [0, 3])
    assert_empty PaddedCell::Scheduler.batches(CLASSES, seed: 1234, shard: [1, 3])
    assert_equal [[3, 7]], PaddedCell::Scheduler.batches(CLASSES, seed: 1234, shard: [2, 3])
  end

  # Regressions: the median of an even number of known durations, -0.0 and
  # 0.0 as one; every bit of a 64-bit seed reaching the planner; the stable
  # hash that places a class in its shard.
  def test_pinned_edges
    durations = [-0.0, 0.0, 0.3, 0.7, 0.9, 1.1, -1.0]

    assert_equal [[5], [4], [3], [6], [2], [0], [1]], PaddedCellNative.plan(%w[Z O B C D E U], durations, 5, 0, 1)
    assert_equal [[7, 3], [4, 1], [6], [0, 5, 2]], PaddedCellNative.plan(CLASSES, [-1.0] * 8, (2**64) - 1, 0, 1)
    { 2 => 0, 3 => 1, 5 => 1, 7 => 5, 11 => 7 }.each do |count, shard|
      assert_equal [[0]], PaddedCellNative.plan(%w[a], [-1.0], 1, shard, count), "shard #{shard} of #{count}"
    end
  end

  def test_shards_partition_the_tests_by_class
    classes = Array.new(200) { "Suite#{it % 23}Test" }
    shards = Array.new(4) { PaddedCell::Scheduler.batches(classes, seed: 9, shard: [it, 4]) }

    assert_equal (0...200).to_a, shards.flatten.sort
    assert_equal 23, shards.sum(&:size)
    shards.flatten(1).each { |batch| assert_equal [classes[batch.first]], batch.map { classes[it] }.uniq }
  end

  def test_seed_decides_the_order
    classes = Array.new(50) { "Suite#{it % 5}Test" }

    assert_equal PaddedCell::Scheduler.batches(classes, seed: 1), PaddedCell::Scheduler.batches(classes, seed: 1)
    refute_equal PaddedCell::Scheduler.batches(classes, seed: 1), PaddedCell::Scheduler.batches(classes, seed: 2)
  end
end
