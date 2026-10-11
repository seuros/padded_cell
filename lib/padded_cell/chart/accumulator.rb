# frozen_string_literal: true

require 'coverage'
require 'fileutils'
require 'tmpdir'

module PaddedCell
  module Chart
    # The runner's side. Starts Ruby's Coverage before the suite loads, hands
    # each worker a Probe, then sums its own measure (loading the suite) with
    # every frame the workers wrote.
    class Accumulator
      attr_reader :criteria

      # criteria: what Ruby's Coverage measures, :lines always among them
      def initialize(criteria)
        @criteria = criteria
        @root = File.realpath(Dir.pwd)
        @roots = [Dir.pwd, @root].uniq.map { "#{it}/" }
        @kept = {}
        @lost = 0
        @known = Set.new
      end

      # Nothing loaded before is measured.
      def start
        ::Coverage.setup(**@criteria.to_h { [it, true] })
        ::Coverage.resume
        @frames = Dir.mktmpdir('padded_cell-coverage')
        self
      end

      # After the suite loaded, before the first fork: the files whose
      # structure the runner will report itself. Forks inherit the set.
      def snapshot
        ::Coverage.peek_result.each_key { @known << it if keep?(it) }
      end

      # For a worker, right after its fork.
      def probe
        Probe.new(file: File.join(@frames, "#{Process.pid}.cov"), known: @known, keep: method(:keep?),
                  methods: @criteria.include?(:methods), interval: Chart.config.interval)
      end

      # A worker died: what it measured since its last flush is gone.
      def lost_worker = @lost += 1

      # Sums everything (see Raw); nil for an interrupted run.
      def finish(interrupted: false)
        return if interrupted

        total = Delta.capture(::Coverage.peek_result, Set.new, method(:keep?))
        cells = 0
        frames.each do |frame|
          Delta.merge!(total, frame[:delta])
          cells += frame[:lost]
        end
        Raw.build(normalize(total), root: @root, criteria: @criteria, lost: { workers: @lost, cells: })
      ensure
        FileUtils.rm_rf(@frames) if @frames
      end

      private

      # Files under the project root, which exist (not eval'd code).
      def keep?(path)
        @kept.fetch(path) { @kept[path] = @roots.any? { path.start_with?(it) } && File.file?(path) }
      end

      # Every complete frame of every worker. A worker killed while writing
      # leaves a truncated last frame, skipped.
      def frames
        Dir[File.join(@frames, '*.cov')].flat_map do |file|
          data = File.binread(file)
          offset = 0
          frames = []
          while offset + 4 <= data.bytesize
            size = data.unpack1('N', offset:)
            break if offset + 4 + size > data.bytesize

            frames << Marshal.load(data.byteslice(offset + 4, size)) # written by our own workers
            offset += 4 + size
          end
          frames
        end
      end

      # Keys by real path relative to the root: a file required through a
      # symlink and through its real path is one file. A file deleted during
      # the run is not reported.
      def normalize(total)
        total.each_with_object({}) do |(path, entry), files|
          relative = File.realpath(path).delete_prefix("#{@root}/")
          next if relative.start_with?('/')

          files[relative] ? Delta.merge!(files, { relative => entry }) : files[relative] = entry
        rescue SystemCallError
          next
        end
      end
    end
  end
end
