# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'padded_cell/asylum'

class RunnerTest < Minitest::Test
  include CLIHelper

  def test_runs_the_suite_once_with_minitest_totals
    run = padded_cell('--no-timings', suite: 'basic')

    assert_equal [6, 4, 1, 1, 1], run.summary
    assert_equal 1, run.exitstatus
    # minitest/autorun in the helper did not run it all a second time.
    assert_equal 1, run.out.scan('# Running:').size
  end

  def test_contains_kills_exits_and_hangs
    run = padded_cell('--no-timings', '--timeout', '1', suite: 'crashy')

    assert_equal [5, 1, 0, 4, 0], run.summary
    ['cell killed by SIGKILL', 'cell exited with status 3 before reporting', 'exit(4) called during the test',
     'timed out after 1.0s'].each { assert_includes run.out, it }
  end

  def test_worker_isolation_replaces_dead_workers
    run = padded_cell('--no-timings', '--timeout', '1', '--isolation', 'worker', '-j', '2', suite: 'crashy')

    assert_equal [5, 1, 0, 4, 0], run.summary
    ['worker killed by SIGKILL', 'worker exited with status 3 before reporting', 'exit(4) called during the test',
     'timed out after 1.0s'].each { assert_includes run.out, it }
  end

  # Results are binary Marshal data: under Rails' Encoding.default_internal a
  # text-mode pipe would try to transcode them, and fail.
  def test_results_cross_processes_under_default_internal
    %w[test worker].each do |isolation|
      run = padded_cell('--no-timings', '--isolation', isolation, suite: 'encoding')

      assert_equal [2, 2, 1, 0, 0], run.summary, "#{isolation}: #{run.err}"
    end
  end

  # A worker (or cell) may load classes the runner never did, like an error
  # class Rails autoloads during a test: its failures still come back whole.
  def test_errors_of_classes_loaded_after_the_fork
    %w[test worker].each do |isolation|
      run = padded_cell('--no-timings', '-j', '1', '--isolation', isolation, suite: 'late_classes')

      assert_equal [3, 1, 0, 2, 0], run.summary, "#{isolation}: #{run.out}#{run.err}"
      assert_includes run.out, 'LateError: defined in the worker'
      assert_includes run.out, 'Late::NestedError: nested, defined in the worker'
    end
  end

  # Without --asylum, a flaky test fails the run like any other failure.
  def test_flaky_tests_fail_without_asylum
    run = flaky_run

    assert_equal [4, 4, 3, 0, 0], run.summary
    assert_equal 1, run.exitstatus
  end

  def test_asylum_retries_and_reports_the_flaky_tests
    Dir.mktmpdir do |dir|
      json = File.join(dir, 'results.jsonl')
      junit = File.join(dir, 'junit.xml')
      run = flaky_run('--asylum', '--json', json, '--junit', junit)
      retry_seed = PaddedCell::Asylum.retry_seed(unlucky_seed, 2)

      assert_equal [4, 4, 1, 0, 0], run.summary, run.out
      assert_equal 1, run.exitstatus, 'a real failure stays one'
      assert_includes run.out, "You're not crazy, the world is. 2 tests failed, then passed:"
      assert_attempts run.out, 'test_passes_when_retried',
                      ['lost the race', "passed, alone → #{PaddedCell::Asylum::ALONE}"]
      assert_attempts run.out, 'test_depends_on_the_seed',
                      ['unlucky seed.', 'unlucky seed. (alone)', "passed, alone → #{PaddedCell::Asylum::RESEEDED}"],
                      seeds: [unlucky_seed, unlucky_seed, retry_seed]
      assert_includes run.out, "It's not the world, it's the test:\n  FlakyTest#test_always_fails failed all 3 attempts"

      entries = File.readlines(json).map { JSON.parse(it) }.to_h { [it['name'], it] }

      assert_equal [3, retry_seed], entries['test_depends_on_the_seed']['flaky'].values_at('attempts', 'seed')
      assert_equal 2, entries['test_passes_when_retried']['flaky']['attempts']
      assert_equal 3, entries['test_always_fails']['asylum']['attempts']
      assert_includes File.read(junit), '<flakyFailure type="Minitest::Assertion" message="lost the race">'
    end
  end

  def test_asylum_passes_the_run_when_every_failure_recovers
    run = flaky_run('--asylum', '-e', 'test_always_fails')

    assert_equal [3, 3, 0, 0, 0], run.summary
    assert_equal 0, run.exitstatus
  end

  # --asylum=1 is one retry, with the run's own seed: not enough for a test
  # that needs another seed.
  def test_asylum_attempts_are_bounded
    run = flaky_run('--asylum=1')

    assert_equal [4, 4, 2, 0, 0], run.summary
    assert_includes run.out, "You're not crazy, the world is. 1 test failed, then passed:"
    assert_includes run.out, '  FlakyTest#test_depends_on_the_seed failed all 2 attempts'
  end

  # Classes run whole, as Minitest and Rails run them: per-class setup such
  # as fixtures happens once.
  def test_a_class_runs_as_one_block
    order = padded_cell('--no-timings', '-v', '-j', '1', suite: 'basic').out.scan(/^(\w+)#\w+ =/).flatten

    assert_equal 6, order.size
    assert_equal 2, order.chunk_while { _1 == _2 }.count, order.inspect
  end

  def test_isolation_defaults_to_worker_with_active_record_fixtures
    assert_includes padded_cell('--no-timings', suite: 'basic').out, '--isolation test'
    assert_includes padded_cell('--no-timings', suite: 'records').out, '--isolation worker'
    assert_includes padded_cell('--no-timings', '--isolation', 'test', suite: 'records').out, '--isolation test'
  end

  def test_cells_isolate_what_a_shared_worker_leaks
    seed, shared = (1..30).lazy.map { [it, leaky(it, 'worker')] }.find do |_, run|
      run.out.index('LeakTest#test_writes') < run.out.index('LeakTest#test_reads')
    end

    assert_equal 1, shared.summary[2], shared.out
    assert_equal 0, leaky(seed, 'test').summary[2]
  end

  def test_after_fork_and_cleanup_hooks_get_worker_indices
    hook_log do |log|
      run = padded_cell('--no-timings', '-j', '3', suite: 'hooks', env: { 'HOOK_LOG' => log })

      assert_equal [8, 8, 0, 0, 0], run.summary
      assert_equal 0, run.exitstatus
      assert_equal ['after_fork 0', 'after_fork 1', 'after_fork 2', 'cleanup 0', 'cleanup 1', 'cleanup 2'],
                   File.readlines(log, chomp: true).sort
    end
  end

  def test_workers_clean_up_concurrently
    %w[test worker].each do |isolation|
      run = padded_cell('--no-timings', '--isolation', isolation, '-j', '2', suite: 'concurrent_cleanup')

      assert_equal [2, 2, 0, 0, 0], run.summary
      assert_equal 0, run.exitstatus, "#{isolation}: #{run.out}#{run.err}"
    end
  end

  def test_cleanup_errors_fail_the_run
    %w[test worker].each do |isolation|
      run = padded_cell('--no-timings', '--isolation', isolation, '-j', '2', suite: 'cleanup_error')

      assert_equal [2, 2, 0, 0, 0], run.summary
      assert_equal 1, run.exitstatus, "#{isolation}: #{run.out}#{run.err}"
      assert_includes run.err, 'worker 0 failed: RuntimeError: cleanup failed'
    end
  end

  # --asylum retries in workers of its own: their cleanup counts too.
  def test_cleanup_errors_of_asylum_retries_fail_the_run
    Dir.mktmpdir do |dir|
      run = padded_cell('--no-timings', '--asylum', suite: 'retry_cleanup', env: { 'FLAKY_DIR' => dir })

      assert_equal [1, 1, 0, 0, 0], run.summary, run.out + run.err
      assert_equal 1, run.exitstatus
      assert_includes run.err, 'worker 0 failed: RuntimeError: retry cleanup failed'
    end
  end

  def test_rails_parallelization_hooks_and_worker_ids
    hook_log do |log|
      run = padded_cell('--no-timings', '-j', '2', suite: 'rails', env: { 'HOOK_LOG' => log })

      assert_equal [3, 3, 0, 0, 0], run.summary, run.out + run.err
      assert_equal ['setup 0', 'setup 1', 'teardown 0', 'teardown 1'], File.readlines(log, chomp: true).sort
    end
  end

  def test_file_line_runs_the_test_spanning_that_line
    run = padded_cell('--no-timings', '-v', 'test/models/user_test.rb:11', suite: 'rails',
                                                                         env: { 'HOOK_LOG' => File::NULL })

    assert_equal [1, 1, 0, 0, 0], run.summary
    assert_includes run.out, 'UserTest#test_knows_its_worker'
  end

  def test_include_and_exclude
    run = padded_cell('--no-timings', '-n', '/upcase|reverse/', '-e', 'test_reverse', suite: 'basic')

    assert_equal [1, 1, 0, 0, 0], run.summary
    assert_equal 0, run.exitstatus
  end

  def test_include_matching_a_failure_fails
    run = padded_cell('--no-timings', '-n', 'test_failure', suite: 'basic')

    assert_equal [1, 1, 1, 0, 0], run.summary
    assert_equal 1, run.exitstatus
  end

  def test_include_matching_nothing_fails
    run = padded_cell('--no-timings', '-n', 'test_nope', suite: 'basic')

    assert_equal 1, run.exitstatus
    assert_includes run.err, 'Nothing ran for filter: test_nope'
  end

  def test_fail_fast_stops_dispatching
    run = padded_cell('--no-timings', '-j', '1', '--fail-fast', '--timeout', '1', suite: 'crashy')
    runs, _assertions, _failures, errors, = run.summary

    assert_equal 1, errors
    assert_operator runs, :<=, 2
  end

  def test_the_seed_reproduces_the_order
    orders = Array.new(2) do
      padded_cell('--no-timings', '-v', '-j', '1', '-s', '7', suite: 'basic').out.scan(/^(\w+#\w+) =/)
    end

    assert_equal 6, orders.first.size
    assert_equal orders.first, orders.last
  end

  def test_load_errors_exit_2
    run = padded_cell('--no-timings', suite: 'broken')

    assert_equal 2, run.exitstatus
    assert_includes run.err, 'broken_test.rb: RuntimeError: this file does not load'
  end

  def test_list_is_static_and_shards_partition_it
    all = padded_cell('--list', suite: 'basic').out.lines(chomp: true)
    shards = (1..3).flat_map { padded_cell('--list', '--shard', "#{it}/3", suite: 'basic').out.lines(chomp: true) }

    assert_equal ['test/math_test.rb:6 MathTest#test_addition', 'test/math_test.rb:10 MathTest#test_failure',
                  'test/math_test.rb:14 MathTest#test_error', 'test/math_test.rb:18 MathTest#test_skip',
                  'test/string_test.rb:6 StringTest#test_upcase', 'test/string_test.rb:10 StringTest#test_reverse'], all
    assert_equal all.sort, shards.sort
  end

  def test_list_filters_method_names
    run = padded_cell('--list', '-n', 'test_upcase', suite: 'basic')

    assert_equal ['test/string_test.rb:6 StringTest#test_upcase'], run.out.lines(chomp: true)
    assert_equal 0, run.exitstatus
  end

  def test_list_filters_qualified_names
    run = padded_cell('--list', '-n', 'StringTest#test_reverse', suite: 'basic')

    assert_equal ['test/string_test.rb:10 StringTest#test_reverse'], run.out.lines(chomp: true)
    assert_equal 0, run.exitstatus
  end

  def test_list_filters_names_with_regex
    run = padded_cell('--list', '-n', '/^StringTest#/', suite: 'basic')

    assert_equal ['test/string_test.rb:6 StringTest#test_upcase',
                  'test/string_test.rb:10 StringTest#test_reverse'], run.out.lines(chomp: true)
    assert_equal 0, run.exitstatus
  end

  def test_list_excludes_matching_names
    run = padded_cell('--list', '-e', 'test_reverse', 'test/string_test.rb', suite: 'basic')

    assert_equal ['test/string_test.rb:6 StringTest#test_upcase'], run.out.lines(chomp: true)
    assert_equal 0, run.exitstatus
  end

  def test_list_combines_include_and_exclude
    run = padded_cell('--list', '-n', '/upcase|reverse/', '-e', 'test_reverse', suite: 'basic')

    assert_equal ['test/string_test.rb:6 StringTest#test_upcase'], run.out.lines(chomp: true)
    assert_equal 0, run.exitstatus
  end

  def test_list_combines_name_and_line_filters
    run = padded_cell('--list', '-n', '/upcase|reverse/', 'test/string_test.rb:11', suite: 'basic')

    assert_equal ['test/string_test.rb:10 StringTest#test_reverse'], run.out.lines(chomp: true)
    assert_equal 0, run.exitstatus
  end

  def test_list_filters_without_loading_files
    run = padded_cell('--list', '-n', '/also/', suite: 'broken')

    assert_equal ['test/broken_test.rb:13 BrokenTest#test_also_found'], run.out.lines(chomp: true)
    assert_equal 0, run.exitstatus
    assert_empty padded_cell('--list', '-e', '/found/', suite: 'broken').out
  end

  def test_list_shards_partition_filtered_tests
    shards = (1..3).flat_map do |index|
      padded_cell('--list', '-n', '/addition|upcase/', '--shard', "#{index}/3", suite: 'basic').out.lines(chomp: true)
    end

    assert_equal ['test/math_test.rb:6 MathTest#test_addition',
                  'test/string_test.rb:6 StringTest#test_upcase'], shards.sort
  end

  def test_junit_and_json_reports
    Dir.mktmpdir do |dir|
      junit = File.join(dir, 'reports/junit.xml')
      json = File.join(dir, 'results.jsonl')
      padded_cell('--no-timings', '--junit', junit, '--json', json, suite: 'basic')
      xml = File.read(junit)

      assert_includes xml, '<testsuites name="padded_cell" tests="6" failures="1" errors="1" skipped="1"'
      assert_includes xml, '<testcase classname="MathTest" name="test_failure" file="test/math_test.rb" line="10"'
      assert_equal %w[error failed passed passed passed skipped],
                   File.readlines(json).map { JSON.parse(it)['status'] }.sort
    end
  end

  def test_timings_are_recorded
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'timings.tsv')
      padded_cell('--timings', path, suite: 'basic')
      ids = File.readlines(path, chomp: true).map { it.split("\t").first }

      assert_equal 6, ids.size
      assert_includes ids, 'MathTest#test_addition'
    end
  end

  private

  # A seed whose first rand(2) is 1, and whose second retry seed gives 0.
  def unlucky_seed
    @unlucky_seed ||= (1..).find do |seed|
      Random.new(seed).rand(2) == 1 && Random.new(PaddedCell::Asylum.retry_seed(seed, 2)).rand(2).zero?
    end
  end

  # The attempt lines of one flaky test, in order, each with its seed.
  def assert_attempts(out, test, outcomes, seeds: [unlucky_seed] * outcomes.size)
    block = out[/^  FlakyTest##{test}\n((?:    seed .*\n)+)/, 1]

    refute_nil block, "no attempts listed for #{test} in:\n#{out}"
    lines = block.lines(chomp: true).map { it.sub(/\A    seed /, '').split(/ {2,}/, 2) }

    assert_equal seeds.map(&:to_s).zip(outcomes), lines
  end

  def flaky_run(*args)
    Dir.mktmpdir do |dir|
      padded_cell('--no-timings', '-s', unlucky_seed.to_s, *args, suite: 'flaky', env: { 'FLAKY_DIR' => dir })
    end
  end

  def leaky(seed, isolation)
    padded_cell('--no-timings', '-v', '-j', '1', '-s', seed.to_s, '--isolation', isolation, suite: 'leaky')
  end

  def hook_log
    Dir.mktmpdir { yield File.join(it, 'hooks.log') }
  end
end
