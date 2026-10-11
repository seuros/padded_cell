# frozen_string_literal: true

module PaddedCell
  module Chart
    # The measuring side, in a worker and in its cells.
    #
    # A fork starts with its line and branch counters at zero, so each process
    # measures only itself; method counters are inherited, and cleared on
    # start when methods are measured.
    #
    # A cell sends its delta to its worker along with its result. The worker
    # adds those to its own measure and appends the sum to its frame file
    # every interval, and once more before its cleanup hooks (which may stop
    # Coverage). A worker killed mid-run loses at most one interval.
    #
    # A flush copies the coverage of every file Ruby loaded, gems included: a
    # few milliseconds in a small app, a few hundred in a big Rails one. The
    # interval stretches to keep flushes under 1% of a worker's time.
    class Probe
      INTERVAL = 10.0
      BUDGET = 100

      def initialize(file:, known:, keep:, methods:, interval: INTERVAL)
        @file = file
        @known = known
        @keep = keep
        @methods = methods
        @interval = interval
        @wait = interval
        @pending = {}
        @lost = 0
      end

      # Right after a fork, before anything runs.
      def start
        ::Coverage.result(stop: false, clear: true) if @methods
        @flushed = Minitest.clock_time
      end

      # The delta of a cell, at its end.
      def capture = Delta.capture(::Coverage.peek_result, @known, @keep)

      # A cell's delta, in its worker.
      def absorb(delta) = Delta.merge!(@pending, delta)

      # A cell that died before reporting.
      def lost = @lost += 1

      # Between tests.
      def tick
        flush if Minitest.clock_time - @flushed >= @wait
      end

      def flush
        started = Minitest.clock_time
        delta = Delta.merge!(Delta.capture(::Coverage.result(stop: false, clear: true), @known, @keep), @pending)
        frame = Marshal.dump({ delta:, lost: @lost })
        File.open(@file, 'ab') { it.write([frame.bytesize].pack('N') + frame) }
        # Dense entries brought their structure to the runner: from now on,
        # the cells forked here send these files sparse.
        delta.each { |path, entry| @known << path if entry[:lines].is_a?(Array) }
        @pending = {}
        @lost = 0
        @flushed = Minitest.clock_time
        # 0: after every test, whatever it costs.
        @wait = @interval.zero? ? 0 : [@interval, (@flushed - started) * BUDGET].max
      end
    end
  end
end
