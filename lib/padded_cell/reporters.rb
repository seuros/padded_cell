# frozen_string_literal: true

require 'fileutils'
require 'json'

module PaddedCell
  # File reporters for CI, next to Minitest's own console output.
  module Reporters
    # Collects results, writes them all at the end.
    class FileReporter < Minitest::AbstractReporter
      def initialize(path)
        super()
        @path = path
        @results = []
      end

      def record(result) = @results << result

      def report
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, render(@results))
      end

      private

      def status(result)
        return :skipped if result.skipped?
        return :error if result.error?

        result.passed? ? :passed : :failed
      end

      def file_and_line(result)
        file, line = result.source_location
        [relative(file.to_s), line]
      end

      def relative(file) = file.delete_prefix("#{Dir.pwd}/")

      # --asylum's report on a test that passed on retry, if it did.
      def flaky(result) = result.metadata? ? result.metadata[:flaky] : nil

      # --asylum's attempts at a test that never passed.
      def asylum(result) = result.metadata? ? result.metadata[:asylum] : nil
    end

    # JUnit XML, as read by GitHub, GitLab, Jenkins and friends.
    class JUnit < FileReporter
      ESCAPES = { '&' => '&amp;', '<' => '&lt;', '>' => '&gt;', '"' => '&quot;', "'" => '&apos;' }.freeze
      # XML 1.0 has no place for most control characters.
      INVALID = /[^\t\n\r -\u{D7FF}\u{E000}-\u{FFFD}\u{10000}-\u{10FFFF}]/

      private

      def render(results)
        suites = results.group_by(&:klass).map { |klass, cases| suite(klass, cases) }
        %(<?xml version="1.0" encoding="UTF-8"?>\n<testsuites name="padded_cell" #{counts(results)}>\n) +
          suites.join + "</testsuites>\n"
      end

      def suite(klass, results)
        %(  <testsuite name="#{escape(klass)}" #{counts(results)}>\n) +
          results.map { testcase(it) }.join + "  </testsuite>\n"
      end

      def counts(results)
        statuses = results.map { status(it) }
        %(tests="#{results.size}" failures="#{statuses.count(:failed)}" errors="#{statuses.count(:error)}" ) +
          %(skipped="#{statuses.count(:skipped)}" time="#{format('%.6f', results.sum(&:time))}")
      end

      def testcase(result)
        file, line = file_and_line(result)
        attributes = %(classname="#{escape(result.klass)}" name="#{escape(result.name)}" file="#{escape(file)}" ) +
                     %(line="#{line}" time="#{format('%.6f', result.time)}" assertions="#{result.assertions}")
        body = outcome(result) + flaky_failure(result)
        body.empty? ? %(    <testcase #{attributes}/>\n) : %(    <testcase #{attributes}>\n#{body}    </testcase>\n)
      end

      # Surefire's element for a test that failed, then passed on retry.
      def flaky_failure(result)
        info = flaky(result)
        return '' unless info

        first = info[:first_failure]
        %(      <flakyFailure type="#{escape(first[:type])}" message="#{escape(first[:message])}">) +
          %(#{escape(info[:cause])}</flakyFailure>\n)
      end

      def outcome(result)
        failure = result.failure
        case status(result)
        when :skipped then %(      <skipped message="#{escape(failure.message)}"/>\n)
        when :error, :failed
          tag = status(result) == :error ? 'error' : 'failure'
          type = failure.is_a?(Minitest::UnexpectedError) ? failure.error.class : failure.class
          %(      <#{tag} type="#{escape(type.to_s)}" message="#{escape(failure.message.lines.first.to_s.strip)}">) +
            %(#{escape(failure.message)}</#{tag}>\n)
        else ''
        end
      end

      def escape(text) = text.to_s.scrub.gsub(INVALID, '').gsub(/[&<>"']/, ESCAPES)
    end

    # --coverage-map: per test, the lines of the project it ran, one JSON
    # object per line, in id order:
    #
    #   {"id":"SignTest#test_zero","file":"test/calc_test.rb","line":28,
    #    "covers":{"lib/calc.rb":[[7,8],10,13]}}
    #
    # Line numbers ascend; [first, last] stands for a run of consecutive
    # ones. Files are those the coverage report would show. A test that was
    # not measured (its cell or worker died) is left out.
    class CoverageMap < FileReporter
      # coverage: the run's Chart::Accumulator
      def initialize(path, coverage:)
        super(path)
        @coverage = coverage
      end

      # A first attempt, as it arrives: what it ran comes off its metadata.
      def record(result)
        covers = result.metadata? && result.metadata.delete(:covers)
        @results << entry(result, covers) if covers
      end

      private

      def render(entries) = entries.sort_by { it[:id] }.map { "#{JSON.generate(it)}\n" }.join

      def entry(result, covers)
        file, line = file_and_line(result)
        { id: "#{result.klass}##{result.name}", file:, line:, covers: files(covers) }
      end

      # Two paths can name one file (a symlink): their lines are merged.
      def files(covers)
        files = Hash.new { |hash, name| hash[name] = [] }
        covers.each do |path, lines|
          name = @coverage.project_file(path)
          files[name].concat(lines) if name
        end
        files.sort.to_h { |name, lines| [name, ranges(lines.uniq.sort)] }
      end

      def ranges(lines)
        lines.slice_when { |previous, line| line != previous + 1 }.map { it.size == 1 ? it[0] : [it[0], it[-1]] }
      end
    end

    # One JSON object per test, one per line.
    class JSONLines < FileReporter
      private

      def render(results) = results.map { "#{JSON.generate(entry(it))}\n" }.join

      def entry(result)
        file, line = file_and_line(result)
        {
          id: "#{result.klass}##{result.name}", class: result.klass, name: result.name, file:, line:,
          status: status(result), time: result.time, assertions: result.assertions,
          failures: result.failures.map { { type: it.result_label, message: it.message.scrub } },
          flaky: flaky(result), asylum: asylum(result)
        }.compact
      end
    end
  end
end
