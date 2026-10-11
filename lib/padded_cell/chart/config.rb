# frozen_string_literal: true

module PaddedCell
  module Chart
    # A PaddedCell.coverage block, in the test helper:
    #
    #   PaddedCell.coverage(:rails) do
    #     track "{app,lib}/**/*.rb"
    #     skip "app/legacy/"
    #     group "Operations", "app/concepts"
    #     minimum line: 90, branch: 80
    #     minimum_by_file line: 50
    #     minimum_by_group "Models", line: 95
    #     maximum_drop line: 1
    #     formats :markdown, :lcov, :json
    #   end
    #
    # Filters and groups match paths (see Filter). What is
    # measured is decided before the suite loads, on the command line:
    # --coverage=lines,branches,methods.
    class Config
      FORMATS = %i[markdown lcov json].freeze
      # Left out unless cleared: bundled gems, hidden files, test files.
      DEFAULT_FILTERS = ['/vendor/bundle/', /\A\..*/, %r{\A(test|features|spec|autotest)/}].freeze
      RAILS_GROUPS = {
        'Channels' => 'app/channels', 'Controllers' => 'app/controllers', 'Helpers' => 'app/helpers',
        'Jobs' => %w[app/jobs app/workers], 'Libraries' => 'lib/', 'Mailers' => 'app/mailers',
        'Models' => 'app/models', 'Views' => 'app/views'
      }.freeze

      attr_reader :filters, :groups, :tracked, :output_formats, :directory, :token, :interval, :minimums,
                  :file_minimums, :group_minimums, :maximum_drops

      def initialize
        @filters = DEFAULT_FILTERS.map { Filter.build(it) }
        @groups = {}
        @tracked = []
        @minimums = {}
        @file_minimums = {}
        @group_minimums = {}
        @maximum_drops = {}
        @output_formats = %i[markdown lcov json]
        @directory = 'coverage'
        @token = 'nocov'
        @interval = Probe::INTERVAL
      end

      # :rails skips config/ and db/, groups the
      # app's directories, tracks {app,lib}/**/*.rb.
      def profile(name)
        raise ArgumentError, "unknown coverage profile #{name.inspect} (known: :rails)" unless name.to_s == 'rails'

        skip(%r{\Aconfig/}, %r{\Adb/})
        RAILS_GROUPS.each { |group_name, filter| group(group_name, filter) }
        track('{app,lib}/**/*.rb')
      end

      # Files to report even when the suite never loads them, at 0%.
      def track(*globs) = @tracked.concat(globs)

      # Files to leave out of the report.
      def skip(*filters, &block)
        filters.each { @filters << Filter.build(it) }
        @filters << Filter.build(&block) if block
      end
      alias filter skip

      # Removes every filter, the defaults included.
      def clear_filters = @filters.clear

      # A file can be in several groups; files in none are Ungrouped.
      # Defining a group again replaces it.
      def group(name, filter = nil, &) = @groups[name.to_s] = Filter.build(filter, &)

      # Thresholds compare percents floored to 2 decimals; a whole, passing
      # run that misses one exits 3.
      def minimum(line: nil, branch: nil, method: nil) = @minimums.merge!({ line:, branch:, method: }.compact)

      # For every file.
      def minimum_by_file(line: nil, branch: nil, method: nil)
        @file_minimums.merge!({ line:, branch:, method: }.compact)
      end

      def minimum_by_group(name, line: nil, branch: nil, method: nil)
        (@group_minimums[name.to_s] ||= {}).merge!({ line:, branch:, method: }.compact)
      end

      # How many points coverage may lose since the previous whole run.
      def maximum_drop(line: nil, branch: nil, method: nil)
        @maximum_drops.merge!({ line:, branch:, method: }.compact)
      end

      def formats(*names)
        unknown = names.map(&:to_sym) - FORMATS
        unless unknown.empty?
          raise ArgumentError, "unknown coverage formats: #{unknown.join(', ')} (known: #{FORMATS.join(', ')})"
        end

        @output_formats = names.map(&:to_sym)
      end

      # Where reports go (default: coverage). --coverage-dir wins.
      def dir(path) = @directory = path

      # `# :nocov:` opens and closes blocks of lines coverage ignores.
      def nocov_token(token) = @token = token

      # How often, at least, a worker hands over what it measured (seconds,
      # default 10, stretched to keep it under 1% of the worker's time; 0:
      # after every test). A worker that dies loses what it measured since.
      def flush_interval(seconds) = @interval = seconds

      # What a report needs once files are filtered and grouped, as stored
      # in its Document.
      def settings
        {
          formats: @output_formats.map(&:to_s), nocov_token: @token, minimum: @minimums,
          minimum_by_file: @file_minimums, minimum_by_group: @group_minimums, maximum_drop: @maximum_drops
        }
      end

      # Criteria come from the command line, before the suite (and this
      # block) loads.
      def enable_coverage(*)
        raise ArgumentError, 'coverage criteria come from --coverage=lines,branches,methods, not the test helper'
      end
    end
  end
end
