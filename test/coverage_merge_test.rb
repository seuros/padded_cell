# frozen_string_literal: true

require_relative 'test_helper'
require 'json'

# --coverage-merge: shards (--shard I/N) merged into one report.
class CoverageMergeTest < Minitest::Test
  include CLIHelper

  SUITE = File.join(Fixtures::SUITES, 'chart')
  PASSING = %w[test/calc_test.rb test/shapes_test.rb test/lazy_test.rb].freeze

  def setup
    @output = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@output)
  end

  # Each shard loads the whole suite: lines run at load time count once per
  # shard. What was covered is the unsharded run's.
  def test_shards_merge_into_the_whole_run
    whole = shard_run('whole')
    # A shard alone checks no threshold; the merge does, with the shards'.
    minimum = { 'COVERAGE_MINIMUM' => '90' }
    shards = [shard_run('one', '--shard', '1/2', env: minimum), shard_run('two', '--shard', '2/2', env: minimum)]
    run = merge(*shards)

    assert_equal 3, run.exitstatus, run.err
    assert_includes run.out, "Line coverage: 24 / 37 (64.86%)\n"
    assert_includes run.out, 'Line coverage (64.86%) is below the expected minimum coverage (90.00%).'
    assert_equal covered(whole), covered(File.join(@output, 'merged'))
  end

  # One shard is not the suite: no threshold, no .last_run.json.
  def test_missing_shards_skip_thresholds
    run = merge(shard_run('one', '--shard', '1/2'))

    assert_equal 0, run.exitstatus, run.err
    refute_path_exists File.join(@output, 'merged', '.last_run.json')
  end

  def test_shards_of_other_sources_are_refused
    shard = shard_run('one')
    path = File.join(shard, '.padded_cell.json')
    document = JSON.parse(File.read(path))
    document['files']['lib/calc.rb']['digest'] = '0' * 64
    File.write(path, JSON.generate(document))
    run = merge(shard)

    assert_equal 2, run.exitstatus
    assert_includes run.err, 'lib/calc.rb differs between the shards or from this checkout'
  end

  private

  def shard_run(name, *args, env: {})
    dir = File.join(@output, name)
    run = padded_cell('--no-timings', '--coverage', '--coverage-dir', dir, *args, *PASSING, suite: 'chart', env:)
    assert_equal 0, run.exitstatus, run.err
    dir
  end

  def merge(*shards)
    padded_cell('--coverage-merge', shards.join(','), '--coverage-dir', File.join(@output, 'merged'), suite: 'chart')
  end

  # {file => [lines covered, branches taken]}, from lcov.info.
  def covered(dir)
    File.read(File.join(dir, 'lcov.info')).split("end_of_record\n").to_h do |record|
      lines = record.scan(/^DA:(\d+),(\d+)$/).filter_map { |line, hits| line if hits.to_i.positive? }
      branches = record.scan(/^BRDA:(\d+),0,(\d+),(\S+)$/).map { |line, index, taken| [line, index, taken != '-'] }
      [record[/^SF:(.*)$/, 1], [lines, branches]]
    end
  end
end
