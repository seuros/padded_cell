# frozen_string_literal: true

require_relative 'test_helper'
require 'json'

# The reports, compared with the references in expected/. When the suite
# changes, update them from a run and review the diff.
class CoverageReportTest < Minitest::Test
  include CLIHelper

  SUITE = File.join(Fixtures::SUITES, 'chart')
  TESTS = %w[test/calc_test.rb test/shapes_test.rb test/lazy_test.rb test/flaky_test.rb].freeze
  PASSING = TESTS - %w[test/flaky_test.rb]

  def setup
    @output = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@output)
  end

  def test_lcov_matches_the_reference_byte_for_byte
    expected = File.read(File.join(SUITE, 'expected/lcov.info'))

    %w[test worker].each do |isolation|
      run = coverage('-j', '4', '--isolation', isolation)

      assert_equal 1, run.exitstatus, run.err
      assert_equal expected, File.read(File.join(@output, 'lcov.info')), isolation
    end
  end

  # All but meta: who wrote it, and when.
  def test_json_matches_the_reference
    expected = JSON.parse(File.read(File.join(SUITE, 'expected/coverage.json')))
    coverage(criteria: 'lines,branches')
    actual = JSON.parse(File.read(File.join(@output, 'coverage.json')))

    assert_equal expected.except('meta'), actual.except('meta')
    keep = %w[schema_version project_name primary_coverage line_coverage branch_coverage method_coverage]
    assert_equal expected['meta'].slice(*keep), actual['meta'].slice(*keep)
    assert_equal 'padded_cell', actual['meta']['command_name']
  end

  # What an agent needs: the code that never ran, the most missed first.
  def test_markdown_lists_the_code_that_never_ran
    coverage(*PASSING)
    markdown = File.read(File.join(@output, 'coverage.md'))

    assert_includes markdown, "# Coverage: Chart\n\nLines 64.86% (24 / 37) · Branches 37.50% (6 / 16)\n"
    assert_includes markdown, "| Core | 90.90% (10 / 11) | 83.33% (5 / 6) |\n"
    assert_includes markdown, "## Missed, most first\n\n### `lib/unused.rb`\n"
    assert_includes markdown, "### `lib/calc.rb`\n\nLines 90.90% (10 / 11) · Branches 83.33% (5 / 6)\n\n" \
                              "Lines never run: 18.\n\nBranches never taken: 27 `else`.\n\n" \
                              "```ruby\n18      :never\n```\n"
  end

  # --coverage=eval: templates compiled with their file name are measured.
  def test_eval_measures_templates
    coverage('eval/view_test.rb', criteria: 'lines,branches,eval')

    assert_includes File.read(File.join(@output, 'lcov.info')),
                    "SF:./lib/greeting.erb\nDA:1,1\nDA:2,1\nDA:4,1\nLF:3\nLH:3\n" \
                    "BRDA:2,0,1,-\nBRDA:2,0,2,1\nend_of_record\n"
  end

  def test_summary
    run = coverage(criteria: 'lines,branches,methods')

    assert_includes run.out, "Coverage report generated for padded_cell to #{@output}\n" \
                             "Line coverage: 24 / 37 (64.86%)\nBranch coverage: 6 / 16 (37.50%)\n" \
                             "Method coverage: 6 / 13 (46.15%)\n"
  end

  def test_a_passing_run_below_a_minimum_exits_3
    run = coverage(*PASSING, env: { 'COVERAGE_MINIMUM' => '90' })

    assert_equal 3, run.exitstatus, run.err
    assert_includes run.out, 'Line coverage (64.86%) is below the expected minimum coverage (90.00%).'
    assert_includes run.out, "  Lowest-coverage files (line):\n      0.00%  lib/early.rb\n"
    assert_equal 0, coverage(*PASSING, env: { 'COVERAGE_MINIMUM' => '64.86' }).exitstatus
  end

  def test_minimums_by_file_and_group
    run = coverage(*PASSING, env: { 'COVERAGE_MINIMUM_BY_FILE' => '50', 'COVERAGE_MINIMUM_CORE' => '95' })

    assert_equal 3, run.exitstatus, run.err
    assert_includes run.out, 'Line coverage by file (0.00%) is below the expected minimum coverage (50.00%) ' \
                             "in lib/early.rb.\n"
    assert_includes run.out, 'Line coverage by group (90.90%) is below the expected minimum coverage (95.00%) ' \
                             "in Core.\n"
    errors = JSON.parse(File.read(File.join(@output, 'coverage.json')))['errors']
    assert_equal({ 'lines' => { 'expected' => 95.0, 'actual' => 90.9 } }, errors['minimum_coverage_by_group']['Core'])
  end

  # A whole passing run records its percents; the next one compares.
  def test_maximum_drop_since_the_last_run
    assert_equal 0, coverage(*PASSING).exitstatus
    assert_equal({ 'result' => { 'line' => 64.86, 'branch' => 37.5 } },
                 JSON.parse(File.read(File.join(@output, '.last_run.json'))))
    File.write(File.join(@output, '.last_run.json'), JSON.generate(result: { line: 99.0 }))
    run = coverage(*PASSING, env: { 'COVERAGE_MAXIMUM_DROP' => '1' })

    assert_equal 3, run.exitstatus
    assert_includes run.out, 'Line coverage has dropped by 34.14% since the last time (maximum allowed: 1.00%).'
  end

  # Failing tests decide the status; a partial run says nothing of the
  # whole suite's coverage.
  def test_minimums_hold_for_whole_passing_runs_only
    failing = coverage(env: { 'COVERAGE_MINIMUM' => '90' })
    filtered = coverage('-n', '/add/', *PASSING, env: { 'COVERAGE_MINIMUM' => '90' })

    assert_equal 1, failing.exitstatus
    assert_equal 0, filtered.exitstatus
    [failing, filtered].each { refute_includes it.out, 'below the expected minimum' }
  end

  def test_files_loaded_before_coverage_started_are_not_reported
    early = File.join(SUITE, 'lib/early.rb')
    run = coverage(*PASSING, env: { 'RUBYOPT' => "-r#{early}" })

    assert_includes run.out, '1 tracked files were loaded before coverage started, and are not reported: lib/early.rb'
    refute_includes File.read(File.join(@output, 'lcov.info')), 'SF:./lib/early.rb'
  end

  def test_the_test_helper_chooses_the_directory_and_the_command_line_wins
    helper = File.join(@output, 'helper')
    run = padded_cell('--no-timings', '--coverage', *PASSING, suite: 'chart', env: { 'COVERAGE_DIR' => helper })

    assert_equal 0, run.exitstatus, run.err
    assert_path_exists File.join(helper, 'lcov.info')
    coverage(*PASSING, env: { 'COVERAGE_DIR' => helper, 'FLAKY_DIR' => Dir.mktmpdir })

    assert_path_exists File.join(@output, 'lcov.info')
  end

  private

  def coverage(*args, criteria: 'lines,branches', env: {})
    files = args.any? { it.end_with?('.rb') } ? [] : TESTS
    padded_cell('--no-timings', "--coverage=#{criteria}", '--coverage-dir', @output, *args, *files,
                suite: 'chart', env: { 'FLAKY_DIR' => Dir.mktmpdir }.merge(env))
  end
end
