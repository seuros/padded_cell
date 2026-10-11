# frozen_string_literal: true

module PaddedCell
  module Chart
    # --coverage-merge: one report from the documents of shards
    # (--shard I/N), here, without loading the suite. Each shard stored its
    # files filtered and grouped, with their settings.
    module Merge
      module_function

      # dirs: the shards' coverage directories.
      def call(dirs, root: File.realpath(Dir.pwd))
        documents = dirs.map { Document.load(it) }
        criteria = documents.map(&:criteria).uniq
        raise ArgumentError, "the shards measured different criteria: #{criteria.join(' / ')}" if criteria.size > 1

        Document.new(
          root:, criteria: criteria.first, lost: lost(documents), shard: shard(documents),
          whole: documents.all?(&:whole), settings: documents.first.settings, files: files(documents, root),
          groups: groups(documents), unmeasured: []
        )
      end

      def lost(documents)
        documents.map(&:lost).reduce { |sum, lost| sum.merge(lost) { |_, left, right| left + right } }
      end

      # [0, 1] when the documents are every shard of a run, once each.
      def shard(documents)
        counts = documents.map { it.shard[1] }.uniq
        indices = documents.map { it.shard[0] }.sort
        counts.size == 1 && indices == (0...counts.first).to_a ? [0, 1] : documents.first.shard
      end

      def groups(documents)
        documents.flat_map { it.groups.to_a }.group_by(&:first).transform_values { it.flat_map(&:last).uniq }
      end

      # A file loaded by any shard is summed over the shards that loaded it;
      # otherwise it is the tracked, never loaded stub.
      def files(documents, root)
        documents.flat_map { it.files.to_a }.group_by(&:first).to_h do |name, entries|
          files = entries.map(&:last)
          same_source!(name, files, root)
          loaded = files.select { it[:loaded] }
          [name, loaded.empty? ? files.first : sum(loaded)]
        end
      end

      def sum(files)
        total = files.each_with_object({}) { |file, sum| Delta.merge!(sum, { file: Raw.entry(file) }) }
        Raw.file(total[:file]).merge(digest: files.first[:digest], loaded: true)
      end

      def same_source!(name, files, root)
        digests = files.map { it[:digest] }.uniq
        return if digests == [Digest::SHA256.file(File.join(root, name)).hexdigest]

        raise ArgumentError, "#{name} differs between the shards or from this checkout: merge reports of one commit"
      end
    end
  end
end
