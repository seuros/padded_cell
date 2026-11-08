# frozen_string_literal: true

require_relative 'test_helper'
require 'json'

class CoverageMapTest < Minitest::Test
  include CLIHelper

  TESTS = %w[test/calc_test.rb test/shapes_test.rb test/lazy_test.rb test/flaky_test.rb].freeze
  CRITERIA = 'lines,branches,methods'
  # Calc#never_called, from an after_fork hook
  AFTER_FORK = { 'AFTER_FORK_CALC' => '1' }.freeze

  def setup
    @output = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@output)
  end

  # Two tests of one file, sharing a worker or not: each maps its own lines,
  # and none what the worker ran around them. A call to a one-line method
  # shows as its def line, from methods.
  def test_each_test_maps_the_lines_it_ran
    %w[test worker].each do |isolation|
      map = map_run('-j', '1', '--isolation', isolation, env: AFTER_FORK)

      assert_equal({ 'lib/calc.rb' => [[7, 9]] }, map['CalcTest#test_positive']['covers'], isolation)
      assert_equal({ 'lib/calc.rb' => [27] }, map['CalcTest#test_maybe']['covers'], isolation)
      assert_equal({ 'lib/calc.rb' => [5] }, map['CalcTest#test_add']['covers'], isolation)
      # Loaded by the test: its load counts too.
      assert_equal({ 'lib/lazy.rb' => [[4, 6], 11] }, map['LazyTest#test_early']['covers'], isolation)
      assert_equal ['test/calc_test.rb', 14], map['CalcTest#test_positive'].values_at('file', 'line')
      assert_empty map.values.flat_map { numbers(it['covers'].fetch('lib/calc.rb', [])) } & [17, 18], isolation
    end
  end

  def test_records_are_in_id_order
    ids = map_run('-j', '3').keys

    assert_equal 11, ids.size
    assert_equal ids.sort, ids
  end

  # Like the coverage report, the map holds first attempts: this one fails
  # before calling Calc#maybe, its retry would not.
  def test_asylum_maps_the_first_attempt
    map = map_run('--asylum')

    assert_empty map['FlakyTest#test_passes_when_retried']['covers']
  end

  # A test whose cell or worker died was not measured: left out, not empty.
  def test_unmeasured_tests_are_left_out
    %w[test worker].each do |isolation|
      map = map_run('-j', '1', '--isolation', isolation, files: [*TESTS, 'crash/crash_test.rb'])

      refute_includes map.keys, 'CrashTest#test_crash', isolation
      assert_includes map.keys, 'CalcTest#test_add', isolation
    end
  end

  def test_the_summed_coverage_does_not_change
    %w[test worker].each do |isolation|
      args = ['--seed', '7', '-j', '2', '--isolation', isolation]
      chart_run(*args, dir: 'off', env: AFTER_FORK)
      chart_run('--coverage-map', map_path, *args, dir: 'on', env: AFTER_FORK)

      %w[.padded_cell.json lcov.info].each do |file|
        assert_equal File.binread(File.join(@output, 'off', file)), File.binread(File.join(@output, 'on', file)),
                     "#{isolation}: #{file}"
      end
    end
  end

  def test_the_map_measures_lines_and_methods_when_coverage_is_off
    chart_run('--coverage-map', map_path, criteria: nil)

    assert_equal %w[lines methods], report['criteria']
    assert_equal({ 'lib/calc.rb' => [5] }, map['CalcTest#test_add']['covers'])
  end

  def test_the_environment_sets_the_map
    chart_run(env: { 'PADDED_CELL_COVERAGE_MAP' => map_path })

    assert_includes map.keys, 'CalcTest#test_add'
  end

  def test_the_command_line_wins_over_the_environment
    from_env = File.join(@output, 'env.jsonl')
    chart_run('--coverage-map', map_path, env: { 'PADDED_CELL_COVERAGE_MAP' => from_env })

    assert_path_exists map_path
    refute_path_exists from_env
  end

  private

  def map_path = File.join(@output, 'map.jsonl')

  # {id => record}, in file order
  def map = File.readlines(map_path).map { JSON.parse(it) }.to_h { [it['id'], it] }

  # [[3, 5], 9] => [3, 4, 5, 9]
  def numbers(lines) = lines.flat_map { it.is_a?(Array) ? (it[0]..it[1]).to_a : it }

  def report = JSON.parse(File.read(File.join(@output, 'coverage', '.padded_cell.json')))

  def map_run(*args, files: TESTS, env: {})
    chart_run('--coverage-map', map_path, *args, files:, env:)
    map
  end

  # A fresh marker directory per run: FlakyTest fails its first attempt.
  def chart_run(*args, criteria: CRITERIA, files: TESTS, dir: 'coverage', env: {})
    coverage = criteria ? ["--coverage=#{criteria}"] : []
    result = padded_cell('--no-timings', *coverage, '--coverage-dir', File.join(@output, dir), *args, *files,
                         suite: 'chart', env: { 'FLAKY_DIR' => Dir.mktmpdir, **env })
    assert_includes [0, 1], result.exitstatus, result.err
    result
  end
end
