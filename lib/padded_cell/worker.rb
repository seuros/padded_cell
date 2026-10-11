# frozen_string_literal: true

module PaddedCell
  # A Pool's worker process. Reads test indices from its socket, runs each
  # (in a Cell, or itself with isolation :worker) and writes back its
  # Minitest::Result as a length-prefixed Marshal frame. Exits once the
  # socket closes.
  class Worker
    # probe: a Chart::Probe when measuring coverage
    def initialize(tests, isolation:, seed:, timeout:, probe:)
      @tests = tests
      @isolation = isolation
      @seed = seed
      @timeout = timeout
      @probe = probe
    end

    # Never returns.
    def run(worker, socket)
      status = 1
      begin
        srand(@seed)
        @probe&.start
        setup_error = after_fork(worker)
        while (line = socket.gets)
          payload = Results.dump(perform(Integer(line), socket, setup_error))
          socket.write([payload.bytesize].pack('N'), payload)
          @probe&.tick
        end
        # Before cleanup, which may stop Coverage.
        @probe&.flush
        Hooks.run_cleanup(worker) unless setup_error
        status = 0
      rescue Exception => e # anything: report it, then exit!
        warn "padded_cell: worker #{worker} failed: #{e.class}: #{e.message}"
      ensure
        exit!(status)
      end
    end

    private

    # A failing after_fork hook fails every test of the worker, the way Rails
    # parallel testing reports a broken parallelize_setup.
    def after_fork(worker)
      Hooks.run_after_fork(worker)
      nil
    rescue StandardError => e
      e
    end

    def perform(index, socket, setup_error)
      klass, name = @tests.fetch(index)
      if setup_error
        Results.crashed(klass, name, "after_fork hook failed: #{setup_error.class}: #{setup_error.message}")
      elsif @isolation == :test
        Cell.run(klass, name, seed: @seed, timeout: @timeout, close: [socket], probe: @probe)
      else
        Cell.execute(klass, name)
      end
    end
  end
end
