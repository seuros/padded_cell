# frozen_string_literal: true

require_relative 'test_helper'
require 'json'

class CoverageTest < Minitest::Test
  include CLIHelper

  SUITE = File.join(Fixtures::SUITES, 'chart')
  TESTS = %w[test/calc_test.rb test/shapes_test.rb test/lazy_test.rb test/flaky_test.rb].freeze
  MEASURED = %w[lib/calc.rb lib/directives.rb lib/lazy.rb lib/shapes.rb].freeze
  CRITERIA = 'lines,branches,methods'

  # The same suite, run serially in one process under Ruby's Coverage.
  SERIAL = <<~RUBY
    require 'coverage'
    Coverage.setup(lines: true, branches: true, methods: true)
    Coverage.resume
    require 'minitest'
    Minitest.singleton_class.prepend(Module.new { def autorun = nil })
    ARGV.each { require File.expand_path(it) }
    Minitest.run(%w[--seed 1])
    require 'padded_cell/chart'
    root = File.realpath(Dir.pwd)
    keep = ->(path) { path.start_with?("\#{root}/") }
    delta = PaddedCell::Chart::Delta.capture(Coverage.result, Set.new, keep)
    files = delta.to_h { |path, entry| [path.delete_prefix("\#{root}/"), entry] }
    puts JSON.generate(PaddedCell::Chart::Raw.build(files, root:, criteria: [], lost: {})[:files])
  RUBY

  # Tests run in parallel: each run reports to a directory of its own.
  def setup
    @output = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@output)
  end

  # Every worker and cell measured, summed: exactly one process's coverage.
  def test_parallel_coverage_equals_a_serial_run
    expected = serial

    %w[test worker].each do |isolation|
      raw = coverage_run('-j', '4', '--isolation', isolation)

      assert_equal({ 'workers' => 0, 'cells' => 0 }, raw['lost'], isolation)
      assert_equal expected.slice(*MEASURED), measured(raw), isolation
    end
  end

  # A file first loaded after the fork still reports its lines that never
  # ran, and its methods are counted once, whatever class owns them.
  def test_files_loaded_after_the_fork_keep_their_structure
    files = coverage_run('-j', '2')['files']

    assert_equal [nil, nil, nil, 1, 1, 1, nil, 0, nil, nil, 1, 0, nil, nil], files['lib/lazy.rb']['lines']
    assert_equal [['Square', 'area', 5, 2, 5, 24, 1], ['GREETER', 'hello', 9, 2, 9, 20, 1],
                  ['GREETER', 'bye', 11, 2, 11, 16, 0]], files['lib/shapes.rb']['methods']
  end

  # Retries pass or fail depending on the world: only first attempts count.
  def test_asylum_retries_are_not_counted
    raw = coverage_run('--asylum')

    assert_equal serial.slice(*MEASURED), measured(raw)
  end

  def test_lost_cells_and_workers_mark_the_report_partial
    { 'test' => 'cells', 'worker' => 'workers' }.each do |isolation, lost|
      raw = coverage_run('-j', '1', '--isolation', isolation, files: [*TESTS, 'crash/crash_test.rb'])

      assert_equal 1, raw['lost'][lost], isolation
    end
  end

  def test_criteria_and_switches
    run = padded_cell('--no-timings', '--coverage', '--no-coverage', '--coverage-dir', @output, *TESTS,
                      suite: 'chart', env:)

    assert_equal 1, run.exitstatus
    refute_path_exists report_path
    assert_equal 2, padded_cell('--coverage=lines,nope', suite: 'chart').exitstatus
    assert_equal %w[lines], coverage_run(criteria: 'lines')['criteria']
  end

  def test_the_environment_turns_coverage_on
    padded_cell('--no-timings', '--coverage-dir', @output, *TESTS, suite: 'chart',
                                                                   env: env.merge('PADDED_CELL_COVERAGE' => 'branches'))

    assert_equal %w[lines branches], report['criteria']
  end

  def test_simplecov_running_too_is_a_usage_error
    run = padded_cell('--no-timings', '--coverage', 'simplecov/simplecov_test.rb', suite: 'chart')

    assert_equal 2, run.exitstatus
    assert_includes run.err, 'SimpleCov is running, and --coverage replaces it'
  end

  private

  # A fresh marker directory per run: FlakyTest fails its first attempt.
  def env = { 'FLAKY_DIR' => Dir.mktmpdir }

  def coverage_run(*args, criteria: CRITERIA, files: TESTS)
    run = padded_cell('--no-timings', "--coverage=#{criteria}", '--coverage-dir', @output, *args, *files,
                      suite: 'chart', env:)
    assert_includes [0, 1], run.exitstatus, run.err
    report
  end

  def report_path = File.join(@output, '.padded_cell.json')

  # The files the suite loaded, as Raw writes them.
  def measured(raw)
    raw['files'].select { |_, file| file['loaded'] }.transform_values { it.except('digest', 'loaded') }
  end

  def report = JSON.parse(File.read(report_path))

  def serial
    out, err, status = Open3.capture3(env, RbConfig.ruby, '-I', CLIHelper::LIB, '-rjson', '-e', SERIAL, *TESTS,
                                      chdir: SUITE)
    assert status.success?, err
    JSON.parse(out.lines.last)
  end
end
