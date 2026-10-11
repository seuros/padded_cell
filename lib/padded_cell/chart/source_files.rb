# frozen_string_literal: true

module PaddedCell
  module Chart
    # The files of a report: those measured and those tracked but never
    # loaded, minus the filtered ones, in path order; and their groups.
    class SourceFiles
      # Tracked templates are not Ruby files Coverage could stub.
      TEMPLATES = /\.(?:erb|haml|slim)\z/

      # Tracked files loaded before measuring started (by a Rails rake task,
      # Bundler.require...): their coverage is unknown, not 0%.
      attr_reader :unmeasured

      # files: Raw's {relative path => {lines:, branches:, methods:}}
      def initialize(files, config:, root:)
        @config = config
        @root = root
        loaded = loaded_features
        never, @unmeasured = tracked(files).partition { !loaded.include?(File.join(root, it)) }
        @rows = (files.map { |name, entry| row(name, entry) } + stubs(never))
                .reject { |path, name| skipped?(path, name) }
                .sort_by { it[1] }
      end

      # [[absolute path, name, lines, branches, methods, loaded], ...], for
      # PaddedCellNative.chart_report.
      attr_reader :rows

      # [[name, [row index, ...]], ...]: the groups with files, then
      # Ungrouped. None without groups.
      def groups
        return [] if @config.groups.empty?

        files = @rows.map { |path, name| SourceFile.new(path, name) }
        grouped = @config.groups.map { |name, filter| [name, files.each_index.select { filter.call(files[it]) }] }
        ungrouped = files.each_index.to_a - grouped.flat_map(&:last)
        (grouped + [['Ungrouped', ungrouped]]).reject { |_, members| members.empty? }
      end

      private

      def row(name, entry) = [File.join(@root, name), name, entry[:lines], entry[:branches], entry[:methods], true]

      # Files never loaded. Ruby compiles them, without running them: while
      # Coverage runs, that gives their lines and branches as if loaded, none
      # covered. Their methods only exist once run: the native side finds
      # them in the source. A file that does not compile has every line but
      # blank and comment ones missed.
      def stubs(names)
        paths = names.map { File.join(@root, it) }
        compiled = paths.select { compile(it) }
        measured = compiled.empty? ? {} : ::Coverage.peek_result
        paths.zip(names).map do |path, name|
          data = measured[path]
          next [path, name, File.readlines(path).map { 0 }, nil, nil, false] unless data

          entry = Raw.file(Delta.dense(data))
          [path, name, entry[:lines], entry[:branches], nil, false]
        end
      end

      def compile(path)
        RubyVM::InstructionSequence.compile_file(path)
      rescue SyntaxError
        false
      end

      def tracked(files)
        @config.tracked.flat_map { Dir.glob(it, base: @root) }.uniq.reject do |name|
          files.key?(name) || TEMPLATES.match?(name) || !File.file?(File.join(@root, name))
        end
      end

      def skipped?(path, name)
        file = SourceFile.new(path, name)
        @config.filters.any? { it.call(file) }
      end

      # Required files, also under the root's real path.
      def loaded_features
        pwd = "#{Dir.pwd}/"
        $LOADED_FEATURES.each_with_object(Set.new) do |feature, set|
          set << feature
          set << File.join(@root, feature.delete_prefix(pwd)) if feature.start_with?(pwd)
        end
      end
    end
  end
end
