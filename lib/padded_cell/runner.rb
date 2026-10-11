# frozen_string_literal: true

require 'etc'
require 'minitest'
require_relative '../padded_cell'
require_relative 'results'
require_relative 'cell'
require_relative 'worker'
require_relative 'pool'
require_relative 'asylum'
require_relative 'loader'
require_relative 'timings'
require_relative 'reporters'

module PaddedCell
  # Running tests needs fork: Windows (and the JVM Rubies) are not supported.
  class Unsupported < StandardError; end

  # Runs a Minitest suite: select, discover, load once, order, fork, report.
  class Runner
    DEFAULTS = {
      paths: [], jobs: Etc.nprocessors, seed: nil, include: nil, exclude: nil, shard: [0, 1],
      isolation: nil, timeout: nil, asylum: nil, fail_fast: false, verbose: false, show_skips: false,
      list: false, junit: nil, json: nil, timings: 'tmp/padded_cell/timings.tsv', coverage: nil,
      coverage_dir: nil, io: $stdout
    }.freeze

    attr_reader :options

    def initialize(**options)
      @options = DEFAULTS.merge(options)
      @options[:seed] ||= (ENV['SEED'] || Random.new_seed).to_i % 0xFFFF
    end

    # Exit status: 0 when everything passed, 1 otherwise, 3 when only
    # coverage is below a minimum, 130 on Ctrl-C.
    def run
      selection = Selection.parse(options[:paths])
      refs = Discovery.call(selection.files)
      filter = Filter.new(selection, refs, include: options[:include], exclude: options[:exclude])
      return list(selection, refs, filter) if options[:list]
      raise Unsupported, 'padded_cell needs fork, which this Ruby does not have' unless Process.respond_to?(:fork)

      @coverage = start_coverage if options[:coverage]
      Loader.call(selection.files, seed: options[:seed])
      refuse_simplecov if @coverage
      if defined?(ActiveSupport::TestCase)
        require_relative 'active_support_hooks'
        ActiveSupportHooks.install
      end
      options[:isolation] ||= default_isolation
      # Coverage thresholds hold for the whole suite only.
      @whole = !selection.line_filtered? && !options[:include] && !options[:exclude]
      execute(Loader.tests.select { filter.call(*it) })
    end

    private

    # Before the suite loads: nothing loaded earlier is measured.
    def start_coverage
      require_relative 'chart'
      Chart::Accumulator.new(options[:coverage]).start
    end

    # Two tools cannot share Ruby's Coverage.
    def refuse_simplecov
      return unless defined?(::SimpleCov) && ::SimpleCov.respond_to?(:pid) && ::SimpleCov.pid

      raise Unsupported, 'SimpleCov is running, and --coverage replaces it: remove SimpleCov.start (and any ' \
                         'SimpleCov.result in parallelize_teardown) from the test helper'
    end

    # A fork per test discards Active Record's connection pool, and with it
    # the fixtures loaded through it: every test would reload them. With
    # fixtures around, tests share their worker instead.
    def default_isolation = defined?(ActiveRecord::FixtureSet) ? :worker : :test

    # Tests as they would run (static discovery, no loading), in file order.
    def list(selection, refs, filter)
      refs = refs.select { selection.covers?(it.file, it.lines) && filter.matches_name?(it.class_name, it.name) }
      kept = Scheduler.batches(refs.map(&:class_name), seed: options[:seed], shard: options[:shard]).flatten.sort
      kept.each do |index|
        ref = refs[index]
        options[:io].puts "#{ref.file.delete_prefix("#{Dir.pwd}/")}:#{ref.start_line} #{ref.id}"
      end
      0
    end

    def execute(tests)
      ids = tests.map { |klass, name| "#{klass}##{name}" }
      timings = Timings.load(options[:timings])
      batches = Scheduler.batches(tests.map { |klass, _| klass.to_s }, durations: ids.map { timings[it] },
                                                                      seed: options[:seed], shard: options[:shard])
      nothing_ran = batches.empty?
      reporter = build_reporter
      reporter.start
      retried = []
      @coverage&.snapshot
      status = dispatch(tests, batches, reporter, retried) { |index, result| timings[ids[index]] = result.time }
      reporter.report
      report_asylum(retried)
      covered = @coverage ? report_coverage(status, reporter) : true
      Timings.save(options[:timings], timings)
      after_run
      result = finish(reporter, status, nothing_ran)
      result.zero? && !covered ? 3 : result
    end

    # Writes the coverage reports, even for a failing run; false when the
    # coverage of a whole, passing, complete run is below a minimum.
    def report_coverage(status, reporter)
      raw = @coverage.finish(interrupted: status == 130)
      return true unless raw

      dir = options[:coverage_dir] || Chart.config.directory
      document = Chart::Document.build(raw, config: Chart.config, shard: options[:shard], whole: @whole)
      document.write(dir)
      check = status.zero? && reporter.passed? && document.complete?
      Chart::Report.new(document, dir:, io: options[:io]).call(check:)
    end

    # Yields each result as it arrives. With --asylum a failure is held back:
    # only its final result, after the retries, is reported. Returns 1 when a
    # worker failed (its cleanup hook), 130 when interrupted, 0 otherwise.
    def dispatch(tests, batches, reporter, retried)
      held = {}
      record = lambda do |index, result|
        reporter.prerecord(*tests[index])
        reporter.record(result)
        retried << result if result.metadata? && (result.metadata[:flaky] || result.metadata[:asylum])
      end
      pool = Pool.new(tests, jobs: options[:jobs], isolation: options[:isolation], seed: options[:seed],
                             timeout: options[:timeout], coverage: @coverage)
      pool.run(batches) do |index, result|
        yield index, result
        failed = failed?(result)
        options[:asylum] && failed ? held[index] = result : record.call(index, result)
        pool.stop! if options[:fail_fast] && failed
      end
      retries_ok = retry_held(tests, held, record)
      pool.success? && retries_ok ? 0 : 1
    rescue Interrupt
      warn 'Interrupted. Exiting...'
      # Failures still waiting for a retry are failures.
      held.each { |index, result| record.call(index, result) }
      130
    end

    # False when a retry's worker failed.
    def retry_held(tests, held, record)
      return true if held.empty?

      asylum = Asylum.new(tests, attempts: options[:asylum], seed: options[:seed], timeout: options[:timeout])
      asylum.call(held) do |index, result|
        held.delete(index)
        record.call(index, result)
      end
      asylum.success?
    end

    def failed?(result) = !result.passed? && !result.skipped?

    # After Minitest's summary: what --asylum found, attempt by attempt.
    def report_asylum(retried)
      flaky, failing = retried.partition { it.metadata[:flaky] }
      report_flaky(flaky) if flaky.any?
      report_failing(failing) if failing.any?
    end

    def report_flaky(flaky)
      io = options[:io]
      tests = flaky.size == 1 ? '1 test' : "#{flaky.size} tests"
      io.puts "\nYou're not crazy, the world is. #{tests} failed, then passed:"
      width = flaky.flat_map { it.metadata[:flaky][:history] }.map { it[:seed].to_s.size }.max
      flaky.each do |result|
        info = result.metadata[:flaky]
        io.puts "\n  #{result.klass}##{result.name}"
        info[:history].each do |attempt|
          io.puts "    seed #{attempt[:seed].to_s.ljust(width)}  #{attempt_line(attempt, info[:cause])}"
        end
      end
    end

    def attempt_line(attempt, cause)
      return "passed, alone → #{cause}" if attempt[:outcome] == 'passed'

      attempt[:alone] ? "#{attempt[:outcome]} (alone)" : attempt[:outcome]
    end

    def report_failing(failing)
      io = options[:io]
      io.puts "\nIt's not the world, it's the test:"
      failing.each { io.puts "  #{it.klass}##{it.name} failed all #{it.metadata[:asylum][:attempts]} attempts" }
    end

    def build_reporter
      reporter = Minitest::CompositeReporter.new
      minitest_options = {
        io: options[:io], seed: options[:seed], args: run_options,
        verbose: options[:verbose], show_skips: options[:show_skips]
      }
      reporter << Minitest::SummaryReporter.new(options[:io], minitest_options)
      reporter << Minitest::ProgressReporter.new(options[:io], minitest_options)
      # Plugins (minitest-reporters, Rails...) may add or swap reporters.
      Minitest.reporter = reporter
      Minitest.init_plugins(minitest_options)
      Minitest.reporter = nil
      reporter << Reporters::JUnit.new(options[:junit]) if options[:junit]
      reporter << Reporters::JSONLines.new(options[:json]) if options[:json]
      reporter
    end

    # What a rerun needs to reproduce this run's order and settings.
    def run_options
      args = "--seed #{options[:seed]} --isolation #{options[:isolation]}"
      options[:asylum] ? "#{args} --asylum=#{options[:asylum]}" : args
    end

    # Minitest.after_run blocks, which autorun would have called.
    def after_run
      Minitest.class_variable_get(:@@after_run).reverse_each(&:call)
    end

    def finish(reporter, status, nothing_ran)
      return status unless status.zero?
      if nothing_ran && options[:include]
        warn "Nothing ran for filter: #{options[:include]}"
        return 1
      end

      reporter.passed? ? 0 : 1
    end
  end
end
