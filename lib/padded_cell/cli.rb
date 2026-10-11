# frozen_string_literal: true

require 'optparse'
require_relative 'runner'
require_relative 'chart'

module PaddedCell
  # The padded_cell command.
  module CLI
    BANNER = <<~TEXT
      Usage: padded_cell [options] [paths...]

      Runs a Minitest (or Rails) test suite, every test in its own forked cell.

      Paths are files, directories, globs or file:line[-line][:line...].
      Without paths: test/**/*_test.rb, minus test/{system,dummy,fixtures}.

    TEXT

    module_function

    # Exit status: 0 passed, 1 failed, 2 usage or load error, 3 coverage below
    # a minimum, 130 interrupted.
    def start(argv, io: $stdout)
      options = { io:, coverage: coverage_criteria(ENV.fetch('PADDED_CELL_COVERAGE', nil)) }
      parser(options).parse!(argv)
      return merge(options) if options[:coverage_merge]

      options[:paths] = argv
      Runner.new(**options).run
    rescue OptionParser::ParseError, ArgumentError, RegexpError, LoadFailure, Unsupported, SystemCallError => e
      warn "padded_cell: #{e.message}"
      2
    end

    def parser(options)
      OptionParser.new do |opts|
        opts.banner = BANNER
        opts.version = VERSION
        runner_options(opts, options)
        coverage_options(opts, options)
        output_options(opts, options)
        opts.on('--version', 'Print the version') do
          options[:io].puts "padded_cell #{VERSION}"
          exit
        end
        opts.on('-h', '--help', 'Show this help') do
          options[:io].puts opts
          exit
        end
      end
    end

    def runner_options(opts, options)
      opts.on('-j', '--jobs N', Integer, "Workers (default: #{Etc.nprocessors})") do
        options[:jobs] = positive(it)
      end
      opts.on('-s', '--seed SEED', Integer, 'Order seed (default: random, or $SEED)') { options[:seed] = seed(it) }
      opts.on('-n', '-i', '--name', '--include PATTERN', 'Only tests matching (/regexp/ or exact name)') do
        options[:include] = it
      end
      opts.on('-e', '-x', '--exclude PATTERN', 'Skip tests matching (/regexp/ or exact name)') do
        options[:exclude] = it
      end
      opts.on('--shard I/N', 'Run shard I of N (1-based), split by class') { options[:shard] = shard(it) }
      opts.on('--isolation MODE', %w[test worker], 'test: a fork per test; worker: tests share their worker ' \
                                                   '(default: worker with Active Record fixtures, else test)') do
        options[:isolation] = it.to_sym
      end
      opts.on('--timeout SECONDS', Float, 'Kill and fail a test running longer') do
        options[:timeout] = positive(it)
      end
      opts.on('--fail-fast', 'Stop dispatching after the first failure') { options[:fail_fast] = true }
      opts.on('--asylum[=N]', Integer, 'Retry failed tests up to N times (default 2) after the run, alone, ' \
                                       'each in a fresh cell; report the flaky ones') do
        options[:asylum] = it.nil? ? 2 : positive(it)
      end
      opts.on('--list', 'List the tests that would run (static, loads nothing)') { options[:list] = true }
    end

    def coverage_options(opts, options)
      opts.on('--[no-]coverage[=CRITERIA]', 'Measure coverage: lines, branches, methods, eval ' \
                                            "(default: #{Chart::DEFAULT_CRITERIA.join(',')}; " \
                                            'or $PADDED_CELL_COVERAGE)') do
        options[:coverage] = coverage_criteria(it.to_s)
      end
      opts.on('--coverage-dir DIR', 'Write coverage reports to DIR (default: coverage, or the test helper\'s)') do
        options[:coverage_dir] = it
      end
      opts.on('--coverage-merge DIR,DIR', Array, 'Merge the coverage of shards (their --coverage-dir) ' \
                                                 'into one report; runs no test') do
        options[:coverage_merge] = it
      end
    end

    # --coverage-merge: 0, or 3 when a threshold is missed.
    def merge(options)
      document = Chart::Merge.call(options[:coverage_merge])
      dir = options[:coverage_dir] || 'coverage'
      document.write(dir)
      Chart::Report.new(document, dir:, io: options[:io]).call(check: document.complete?) ? 0 : 3
    end

    def output_options(opts, options)
      opts.on('-v', '--verbose', 'One line per test, with timings') { options[:verbose] = true }
      opts.on('--show-skips', 'Show skipped tests at the end') { options[:show_skips] = true }
      opts.on('--junit PATH', 'Also write JUnit XML to PATH') { options[:junit] = it }
      opts.on('--json PATH', 'Also write JSON lines to PATH') { options[:json] = it }
      opts.on('--timings PATH', 'Timings file (default: tmp/padded_cell/timings.tsv)') { options[:timings] = it }
      opts.on('--no-timings', 'Neither read nor write timings') { options[:timings] = nil }
    end

    # The planner takes an unsigned 64-bit seed.
    def seed(value)
      raise OptionParser::InvalidArgument, "#{value} (must be 0 to 2**64 - 1)" unless value.between?(0, (2**64) - 1)

      value
    end

    # OptionParser names the switch in the message.
    def positive(value)
      raise OptionParser::InvalidArgument, "#{value} (must be positive)" unless value.positive?

      value
    end

    # "branches,methods" => [:lines, :branches, :methods] (lines always);
    # "1" or "true" => the defaults; nil, "", "0" or "false" => off.
    def coverage_criteria(value)
      value = value.to_s.strip.downcase
      return if ['', '0', 'false'].include?(value)
      return Chart::DEFAULT_CRITERIA if %w[1 true].include?(value)

      names = value.split(',').map { it.strip.to_sym }
      unknown = names - Chart::CRITERIA
      unless unknown.empty?
        raise OptionParser::InvalidArgument, "coverage #{unknown.join(',')} (known: #{Chart::CRITERIA.join(', ')})"
      end

      [:lines] | names
    end

    def shard(value)
      index, count = value.split('/', 2).map { Integer(it, 10, exception: false) }
      unless index && count&.positive? && index.between?(1, count)
        raise OptionParser::InvalidArgument, "--shard #{value} (expected I/N, 1 <= I <= N)"
      end

      [index - 1, count]
    end
  end
end
