# frozen_string_literal: true

module PaddedCell
  module Chart
    # The coverage of one process, made to cross to another one and be summed
    # there:
    #
    #   {path => {lines:, branches:, methods:}}
    #
    #   lines     Array, nil where there is no code (dense), or {index => hits}
    #   branches  {[type, l1, c1, l2, c2] => {[type, l1, c1, l2, c2] => hits}}
    #   methods   {[name, l1, c1, l2, c2] => [owner, hits]}
    #
    # A dense entry carries the structure of its file, zeros included. A
    # sparse one holds only what ran, for files whose structure the receiver
    # has from elsewhere (the runner loaded them before forking). Keys are
    # source positions: Ruby's branch ids change with every compile, and
    # method owners (anonymous classes) differ between processes.
    module Delta
      module_function

      # result: Ruby's Coverage.result or peek_result. Files in known become
      # sparse entries, or nothing when none of their code ran; files for
      # which keep is false are left out.
      def capture(result, known, keep)
        delta = {}
        result.each do |path, data|
          next unless keep.call(path)

          if known.include?(path)
            entry = sparse(data)
            delta[path] = entry if entry
          else
            delta[path] = dense(data)
          end
        end
        delta
      end

      # Adds delta into total (both deltas). Sums hits; a dense entry brings
      # its structure along. Order does not matter.
      def merge!(total, delta)
        delta.each do |path, entry|
          into = total[path]
          next total[path] = copy(entry) unless into

          into[:lines] = merge_lines(into[:lines], entry[:lines])
          merge_branches(into[:branches] ||= {}, entry[:branches]) if entry[:branches]
          merge_methods(into[:methods] ||= {}, entry[:methods]) if entry[:methods]
        end
        total
      end

      # Coverage's arrays are frozen.
      def dense(data)
        {
          lines: data[:lines].dup,
          branches: data[:branches] && branches(data[:branches], all: true),
          methods: data[:methods] && methods(data[:methods], all: true)
        }.compact
      end

      # nil when nothing in the file ran. Branches only run on lines that ran;
      # a method can run without a line (an empty body), so methods are
      # looked at either way.
      def sparse(data)
        lines = data[:lines]
        ran = (lines.compact.max || 0).positive?
        methods = data[:methods] && methods(data[:methods], all: false)
        return if !ran && (methods.nil? || methods.empty?)

        entry = { lines: ran ? sparse_lines(lines) : {} }
        entry[:branches] = branches(data[:branches], all: false) if ran && data[:branches]
        entry[:methods] = methods if methods
        entry
      end

      def sparse_lines(lines)
        hits = {}
        lines.each_with_index { |count, index| hits[index] = count if count&.positive? }
        hits
      end

      def branches(raw, all:)
        raw.each_with_object({}) do |(condition, arms), out|
          kept = {}
          arms.each { |arm, hits| kept[position(arm)] = hits if all || hits.positive? }
          out[position(condition)] = kept if all || !kept.empty?
        end
      end

      def methods(raw, all:)
        raw.each_with_object({}) do |(key, hits), out|
          next unless all || hits.positive?

          owner, name, *span = key
          entry = out[[name, *span]]
          entry ? entry[1] += hits : out[[name, *span]] = [owner.name || owner.inspect, hits]
        end
      end

      # [type, id, first line, first column, last line, last column], minus
      # the id.
      def position(key) = [key[0], key[2], key[3], key[4], key[5]]

      def copy(entry)
        {
          lines: entry[:lines].dup,
          branches: entry[:branches]&.transform_values(&:dup),
          methods: entry[:methods]&.transform_values(&:dup)
        }.compact
      end

      # Dense + dense sums by index (an eval'd file can grow); dense + sparse
      # adds the sparse hits; sparse + sparse sums by index.
      def merge_lines(into, lines)
        return add_sparse(lines.dup, into) if into.is_a?(Hash) && lines.is_a?(Array)
        return add_sparse(into, lines) if lines.is_a?(Hash)

        lines.each_with_index do |hits, index|
          next unless hits

          into[index] = (into[index] || 0) + hits
        end
        into
      end

      def add_sparse(into, sparse)
        sparse.each { |index, hits| into[index] = (into[index] || 0) + hits }
        into
      end

      def merge_branches(into, branches)
        branches.each do |condition, arms|
          kept = into[condition] ||= {}
          arms.each { |arm, hits| kept[arm] = (kept[arm] || 0) + hits }
        end
      end

      def merge_methods(into, methods)
        methods.each do |key, (owner, hits)|
          entry = into[key]
          entry ? entry[1] += hits : into[key] = [owner, hits]
        end
      end
    end
  end
end
