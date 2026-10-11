# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'

module PaddedCell
  module Chart
    # What a report is made from, as stored in coverage/.padded_cell.json:
    # the files once filtered, tracked and grouped, and the report settings.
    # --coverage-merge sums the documents of shards without loading the
    # suite.
    #
    #   files   {name => {digest:, loaded:, lines:, branches:, methods:}} (see Raw)
    #   groups  {group name => [file name, ...]}
    #   shard   [index, count], 0-based
    #   whole   the run selected no test by name or line
    Document = Data.define(:root, :criteria, :lost, :shard, :whole, :settings, :files, :groups, :unmeasured) do
      def self.build(raw, config:, shard:, whole:)
        source_files = SourceFiles.new(raw[:files], config:, root: raw[:root])
        files = source_files.rows.to_h do |path, name, lines, branches, methods, loaded|
          [name, { digest: Digest::SHA256.file(path).hexdigest, loaded:, lines:, branches:, methods: }.compact]
        end
        groups = source_files.groups.to_h { |name, indices| [name, indices.map { source_files.rows[it][1] }] }
        new(root: raw[:root], criteria: raw[:criteria].map(&:to_s), lost: raw[:lost], shard:, whole:,
            settings: config.settings, files:, groups:, unmeasured: source_files.unmeasured)
      end

      def self.load(dir)
        data = JSON.parse(File.read(File.join(dir, '.padded_cell.json')), symbolize_names: true)
        raise ArgumentError, "#{dir}: not a padded_cell coverage document" unless data[:format] == Document::FORMAT

        new(root: data[:root], criteria: data[:criteria], lost: data[:lost], shard: data[:shard],
            whole: data[:whole], settings: data[:settings], unmeasured: [],
            files: data[:files].transform_keys(&:to_s), groups: data[:groups].transform_keys(&:to_s))
      end

      # [[absolute path, name, lines, branches, methods, loaded], ...] in
      # name order, for PaddedCellNative.chart_report.
      def rows
        files.sort.map do |name, file|
          [File.join(root, name), name, file[:lines], file[:branches], file[:methods], file[:loaded]]
        end
      end

      # [[group name, [row index, ...]], ...]
      def group_rows
        index = files.keys.sort.each_with_index.to_h
        groups.map { |name, names| [name, names.map { index.fetch(it) }.sort] }
      end

      # Every shard of a whole run, and nothing lost: thresholds apply.
      def complete? = whole && shard[0].zero? && shard[1] == 1 && lost.values.all?(&:zero?)

      def write(dir)
        FileUtils.mkdir_p(dir)
        data = { format: Document::FORMAT, version: 1, **to_h.except(:unmeasured) }
        File.write(File.join(dir, '.padded_cell.json'), JSON.generate(data))
      end
    end

    Document::FORMAT = 'padded_cell-coverage'
  end
end
