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
  # mid-test, or runs past its deadline (--timeout, --budget), gets its test
  # reported as an error and is replaced; its replacement continues the class.
  #
  # Replaced, up to a point: workers that keep dying (a boot that segfaults,
  # an after_fork hook that exits) would turn every remaining test into a
  # crash report. Past PaddedCellNative::Restarts' limit the pool gives up.
  # Once the run's budget is spent, it dispatches nothing more.
  class Pool
    Slot = Struct.new(:worker, :pid, :socket, :test, :started, :batch, :deadline)

    # Tests left undispatched by stop! (--fail-fast, the budget, giving up).
    attr_reader :undispatched

    # Why the pool gave up on its workers, or nil.
    attr_reader :gave_up

    # tests: [[klass, method_name], ...], dispatched by index.
    # limits: the run's Limits
    # coverage: a Chart::Accumulator when measuring coverage
    def initialize(tests, jobs:, isolation:, seed:, limits: Limits.new, coverage: nil)
      @tests = tests
      @jobs = jobs
      @isolation = isolation
      @seed = seed
      @limits = limits
      @coverage = coverage
      @restarts = PaddedCellNative::Restarts.new(jobs)
      @undispatched = 0
    end

    # Runs batches of test indices in order (consuming them), yielding
    # (index, result) as results arrive.
    def run(batches, &on_result)
      @queue = batches
      @on_result = on_result
      @sockets = []
      Hooks.run_before_fork
      @slots = Array.new([@jobs, batches.sum(&:size)].min) { spawn(Slot.new(it, nil, nil, nil, nil, [], nil)) }
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
      @undispatched += @queue.sum(&:size) + @slots.sum { it.batch.size }
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
        Worker.new(@tests, isolation: @isolation, seed: @seed, limits: @limits, probe: @coverage&.probe)
              .run(slot.worker, child)
      end
      child.close
      @sockets << parent
      slot.socket = parent
      slot
    end

    def feed(slot)
      return stop! if @limits.spent?

      slot.batch = @queue.shift || steal if slot.batch.empty?
      slot.test = slot.batch.shift
      return unless slot.test

      slot.started = Minitest.clock_time
      slot.deadline = @limits.for_test
      begin
        slot.socket.puts(slot.test)
      rescue Errno::EPIPE, Errno::ECONNRESET
        # The worker died between tests: its replacement gets this one, unless
        # it dies too. Restarts bounds the retries.
        reap(slot)
        @coverage&.lost_worker
        return abandon(slot) unless @restarts.died(Limits.now)

        spawn(slot)
        retry
      end
    end

    # The second half of the largest remainder of another class.
    def steal
      victim = @slots.max_by { it.batch.size }
      victim.batch.pop(victim.batch.size - (victim.batch.size / 2))
    end

    def receive(slot)
      header = read_frame(slot, 4)
      return died(slot) unless header&.bytesize == 4

      size = header.unpack1('N')
      payload = read_frame(slot, size)
      return died(slot) unless payload&.bytesize == size

      report(slot, Results.load(payload, *@tests.fetch(slot.test)))
      feed(slot)
    end

    # nil when the worker died: EOF, or a reset when it left data unread.
    def read_frame(slot, size)
      slot.socket.read(size)
    rescue Errno::ECONNRESET
      nil
    end

    def report(slot, result)
      index = slot.test
      slot.test = nil
      @on_result.call(index, result)
    end

    def died(slot)
      status = reap(slot)
      give_up unless @restarts.died(Limits.now)
      replace(slot, Results.describe(status, 'worker'), Minitest.clock_time - slot.started)
    end

    # Stops replacing workers: whatever was not dispatched is not run.
    def give_up
      window = PaddedCellNative::Restarts.window_ns / Limits::NS
      @gave_up = "workers died more than #{@restarts.limit} times in #{window}s"
      stop!
    end

    # A test taken for a worker that died before receiving it, and is not
    # replaced.
    def abandon(slot)
      slot.test = nil
      @undispatched += 1
      give_up
    end

    # Cells meet their deadline inside their worker; with :worker isolation
    # the runner kills the worker itself.
    def wait_time(busy)
      return unless @isolation == :worker

      now = Limits.now
      busy.filter_map { Limits.remaining(it.deadline, now) }.min
    end

    def expire(busy)
      now = Limits.now
      busy.each do |slot|
        next unless slot.deadline.expired?(now)

        Process.kill(:KILL, slot.pid)
        reap(slot)
        replace(slot, @limits.message(slot.deadline), Minitest.clock_time - slot.started)
      end
    end

    # Reports the running test of a dead worker and starts a new one.
    def replace(slot, message, time)
      @coverage&.lost_worker
      klass, name = @tests.fetch(slot.test)
      report(slot, Results.crashed(klass, name, message, time:))
      stop! if @limits.spent?
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
