# frozen_string_literal: true

module PaddedCell
  module Chart
    # The summed coverage as plain data (coverage/.padded_cell.json): what
    # the reports are made from, and what shards merge.
    #
    #   files: {relative path => {lines:, branches:, methods:}}
    #     lines     [hits or nil, ...] by line
    #     branches  [[type, l1, c1, l2, c2, [[type, l1, c1, l2, c2, hits], ...]], ...]
    #     methods   [[owner, name, l1, c1, l2, c2, hits], ...]
    module Raw
      module_function

      def build(files, root:, criteria:, lost:)
        {
          format: 'padded_cell-coverage', version: 1, root:, criteria:, lost:,
          files: files.sort.to_h { |path, entry| [path, file(entry)] }
        }
      end

      # Every file reaches the runner dense at least once (the runner's own
      # measure covers what it loaded, forks send the rest dense): lines is
      # an Array by now. Branches keep Ruby's order, the order they were
      # compiled in, which reports number them by; methods come in heap
      # order, different in every process: sorted by position.
      def file(entry)
        {
          lines: entry[:lines],
          branches: entry[:branches]&.map do |condition, arms|
            [*condition, arms.map { |arm, hits| [*arm, hits] }]
          end,
          methods: entry[:methods]&.sort_by { |(name, *span), _| [span, name] }
                                 &.map { |(name, *span), (owner, hits)| [owner, name, *span, hits] }
        }.compact
      end

      # file's inverse: a dense Delta entry.
      def entry(file)
        {
          lines: file[:lines].dup,
          branches: file[:branches]&.to_h { |row| [row[0, 5], row[5].to_h { |arm| [arm[0, 5], arm[5]] }] },
          methods: file[:methods]&.to_h { |owner, name, *span, hits| [[name, *span], [owner, hits]] }
        }.compact
      end
    end
  end
end
