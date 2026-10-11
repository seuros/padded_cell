# frozen_string_literal: true

require 'socket'

module PaddedCell
  # Forked workers fed one test at a time over a socket pair. A worker writes
  # back each Minitest::Result as a length-prefixed Marshal frame.
  #
  # Work comes in batches, one per class: a worker takes a whole class, so
  # per-class setup (fixtures) happens once. When no class is left in the
  # queue, an idle worker takes the second half of the largest remainder of
  # another worker's class, so one big class still spreads over all workers.
  #
  # With isolation :test a worker forks a Cell per test; with :worker it runs
  # tests itself, faster but sharing process state. A worker that dies
  # mid-test, or runs past the timeout, gets its test reported as an error and
  # is replaced; its replacement continues the class.
  class Pool
    Slot = Struct.new(:worker, :pid, :socket, :test, :started, :batch)

    # tests: [[klass, method_name], ...], dispatched by index.
    # coverage: a Chart::Accumulator when measuring coverage
    def initialize(tests, jobs:, isolation:, seed:, timeout: nil, coverage: nil)
      @tests = tests
      @jobs = jobs
      @isolation = isolation
      @seed = seed
      @timeout = timeout
      @coverage = coverage
    end

    # Runs batches of test indices in order (consuming them), yielding
    # (index, result) as results arrive.
    def run(batches, &on_result)
      @queue = batches
      @on_result = on_result
      @sockets = []
      Hooks.run_before_fork
      @slots = Array.new([@jobs, batches.sum(&:size)].min) { spawn(Slot.new(it, nil, nil, nil, nil, [])) }
      @slots.each { feed(it) }
      loop do
        busy = @slots.select(&:test)
        break if busy.empty?

        ready, = IO.select(busy.map(&:socket), nil, nil, wait_time(busy))
        ready ? ready.each { |io| receive(busy.find { it.socket == io }) } : expire(busy)
      end
    ensure
      shutdown(force: !$!.nil?)
    end

    def success? = @success

    # Dispatch nothing more; tests already running still report.
    def stop!
      @queue.clear
      @slots.each { it.batch.clear }
    end

    private

    def spawn(slot)
      parent, child = UNIXSocket.pair
      $stdout.flush
      $stderr.flush
      slot.pid = Process.fork do
        # A worker holding another worker's socket would keep it from ever
        # seeing EOF: keep only its own end.
        [parent, *@sockets].each(&:close)
        Worker.new(@tests, isolation: @isolation, seed: @seed, timeout: @timeout, probe: @coverage&.probe)
              .run(slot.worker, child)
      end
      child.close
      @sockets << parent
      slot.socket = parent
      slot
    end

    def feed(slot)
      slot.batch = @queue.shift || steal if slot.batch.empty?
      slot.test = slot.batch.shift
      return unless slot.test

      slot.started = Minitest.clock_time
      begin
        slot.socket.puts(slot.test)
      rescue Errno::EPIPE, Errno::ECONNRESET
        # The worker died between tests: its replacement gets this one.
        reap(slot)
        @coverage&.lost_worker
        spawn(slot).socket.puts(slot.test)
      end
    end

    # The second half of the largest remainder of another class.
    def steal
      victim = @slots.max_by { it.batch.size }
      victim.batch.pop(victim.batch.size - (victim.batch.size / 2))
    end

    def receive(slot)
      header = slot.socket.read(4)
      return died(slot) unless header&.bytesize == 4

      size = header.unpack1('N')
      payload = slot.socket.read(size)
      return died(slot) unless payload&.bytesize == size

      report(slot, Results.load(payload, *@tests.fetch(slot.test)))
      feed(slot)
    end

    def report(slot, result)
      index = slot.test
      slot.test = nil
      @on_result.call(index, result)
    end

    def died(slot)
      status = reap(slot)
      replace(slot, Results.describe(status, 'worker'), Minitest.clock_time - slot.started)
    end

    # Cells time out inside their worker; with :worker isolation the runner
    # kills the worker itself.
    def wait_time(busy)
      return unless @timeout && @isolation == :worker

      deadline = busy.map { it.started + @timeout }.min
      [deadline - Minitest.clock_time, 0].max
    end

    def expire(busy)
      busy.each do |slot|
        next if Minitest.clock_time - slot.started < @timeout

        Process.kill(:KILL, slot.pid)
        reap(slot)
        replace(slot, "timed out after #{@timeout}s", @timeout)
      end
    end

    # Reports the running test of a dead worker and starts a new one.
    def replace(slot, message, time)
      @coverage&.lost_worker
      klass, name = @tests.fetch(slot.test)
      report(slot, Results.crashed(klass, name, message, time:))
      return if @queue.empty? && @slots.all? { it.batch.empty? }

      spawn(slot)
      feed(slot)
    end

    def reap(slot)
      close_socket(slot)
      wait_for(slot)
    end

    def close_socket(slot)
      @sockets.delete(slot.socket)
      slot.socket.close
    end

    def wait_for(slot)
      _, status = Process.wait2(slot.pid)
      slot.pid = nil
      status
    end

    # Closing a socket tells its worker to finish. On an error in the runner
    # (Interrupt included) workers are killed instead of awaited.
    def shutdown(force:)
      live = Array(@slots).select(&:pid)
      live.each { Process.kill(:KILL, it.pid) } if force
      live.each { close_socket(it) }
      @success = live.map { wait_for(it) }.all?(&:success?)
    end
  end
end
