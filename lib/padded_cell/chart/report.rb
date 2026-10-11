# frozen_string_literal: true

require 'json'
require 'open3'
require 'time'

module PaddedCell
  module Chart
    # Writes the reports (natively), prints the summary, and reports the
    # thresholds missed.
    class Report
      Stats = Data.define(:covered, :missed, :omitted, :hits, :percent, :strength) do
        def total = covered + missed
      end
      CRITERIA = { lines: :line, branches: :branch, methods: :method }.freeze
      WORST_FILES = 5

      def initialize(document, dir:, io:)
        @document = document
        @settings = document.settings
        @dir = dir
        @io = io
      end

      # check: a whole, passing run: thresholds decide, and .last_run.json
      # records it. False when a threshold is missed.
      def call(check:)
        result = PaddedCellNative.chart_report(@document.rows, @document.group_rows, options(check))
        @total = stats(result[:total])
        @files = result[:files].map { |name, file| [name, stats(file)] }
        summary
        warn_lost
        return true unless check

        result[:violations].each { report_violation(*it) }
        result[:violations].empty?
      end

      private

      def options(check)
        now = Time.now
        root = @document.root
        {
          dir: File.expand_path(@dir), formats: @settings[:formats], nocov_token: @settings[:nocov_token],
          criteria: criteria.map(&:to_s), write_last_run: check, last_run: last_run,
          minimum: limits(@settings[:minimum]), minimum_by_file: limits(@settings[:minimum_by_file]),
          minimum_by_group: @settings[:minimum_by_group].map { |name, minimums| [name.to_s, limits(minimums)] },
          maximum_drop: limits(@settings[:maximum_drop]),
          root:, timestamp: now.iso8601(3), created_at: now.to_f, commit: commit(root),
          project_name: File.basename(root).capitalize.tr('_', ' '), generator: "padded_cell #{VERSION}"
        }
      end

      # [line, branch, method], nil where unset.
      def limits(values) = %i[line branch method].map { values[it]&.to_f }

      # The previous whole run's percents.
      def last_run
        previous = JSON.parse(File.read(File.join(@dir, '.last_run.json')), symbolize_names: true)[:result] || {}
        limits({ line: previous[:line] || previous[:covered_percent], branch: previous[:branch],
                 method: previous[:method] })
      rescue Errno::ENOENT, JSON::ParserError
        [nil, nil, nil]
      end

      def commit(root)
        out, status = Open3.capture2e('git', '-C', root, 'rev-parse', 'HEAD')
        out.strip if status.success?
      rescue SystemCallError
        nil
      end

      def stats(row) = row.transform_values { Stats.new(*it) }

      # The criteria measured, as stats keys.
      def criteria = @document.criteria.filter_map { CRITERIA[it.to_sym] }

      def summary
        @io.puts "\nCoverage report generated for padded_cell to #{@dir}"
        criteria.each do |criterion|
          stat = @total[criterion]
          next if criterion != :line && stat.total.zero?

          @io.puts format('%<label>s coverage: %<covered>d / %<total>d (%<percent>.2f%%)',
                          label: criterion.capitalize, covered: stat.covered, total: stat.total,
                          percent: stat.percent.floor(2))
        end
      end

      def warn_lost
        lost = @document.lost
        unmeasured = @document.unmeasured
        if lost[:workers].positive? || lost[:cells].positive?
          @io.puts "Coverage is partial: #{lost[:workers]} workers and #{lost[:cells]} cells died before handing " \
                   'over what they measured'
        end
        return if unmeasured.empty?

        @io.puts "#{unmeasured.size} tracked files were loaded before coverage started, and are not reported: " \
                 "#{unmeasured.first(3).join(', ')}#{', ...' if unmeasured.size > 3}"
      end

      def report_violation(scope, name, criterion, limit, actual)
        label = criterion.capitalize
        @io.puts case scope
                 when :drop
                   format('%<label>s coverage has dropped by %<actual>.2f%% since the last time ' \
                          '(maximum allowed: %<limit>.2f%%).', label:, actual:, limit:)
                 when :total then format('%<label>s coverage (%<actual>.2f%%) is below the expected minimum ' \
                                         'coverage (%<limit>.2f%%).', label:, actual:, limit:)
                 else format('%<label>s coverage by %<scope>s (%<actual>.2f%%) is below the expected minimum ' \
                             'coverage (%<limit>.2f%%) in %<name>s.', label:, scope:, actual:, limit:, name:)
                 end
        worst_files(criterion) if scope == :total
      end

      def worst_files(criterion)
        worst = @files.map { |name, file| [name, file[criterion].percent] }.select { it[1] < 100 }
                      .min_by(WORST_FILES) { it[1] }
        return if worst.empty?

        @io.puts "  Lowest-coverage files (#{criterion}):"
        worst.each { |name, percent| @io.puts format('    %<percent>6.2f%%  %<name>s', percent:, name:) }
      end
    end
  end
end
