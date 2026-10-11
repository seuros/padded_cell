# frozen_string_literal: true

module PaddedCell
  # One test in its own forked process. Whatever the test does to its process
  # (crash, exit, hang, monkey patches, leaked threads) stays in the cell.
  module Cell
    CHUNK = 65_536

    module_function

    # Runs klass#name in a fork and returns its Minitest::Result, or an error
    # result when the cell died or ran past timeout seconds.
    #
    #   close: descriptors the cell must not keep open (the worker's socket)
    #   probe: the worker's Chart::Probe, which gets the cell's coverage
    def run(klass, name, seed:, timeout: nil, close: [], probe: nil)
      # Binary: the result is Marshal data, and with Encoding.default_internal
      # set (Rails sets it) a text-mode pipe transcodes what is written to it.
      reader, writer = IO.pipe
      [reader, writer].each(&:binmode)
      started = Minitest.clock_time
      pid = fork_cell(klass, name, seed, reader, writer, close, probe)
      writer.close
      delta, result = collect(pid, reader, klass, name, started, timeout)
      delta ? probe.absorb(delta) : probe&.lost
      result
    ensure
      reader&.close
      writer&.close unless writer&.closed?
    end

    # Runs klass#name in this process. A test calling exit is reported as an
    # error instead of ending the process.
    def execute(klass, name)
      klass.new(name).run
    rescue SystemExit => e
      Results.crashed(klass, name, "exit(#{e.status}) called during the test")
    end

    def fork_cell(klass, name, seed, reader, writer, close, probe)
      $stdout.flush
      $stderr.flush
      Process.fork do
        status = 1
        begin
          reader.close
          close.each(&:close)
          srand(seed)
          probe&.start
          result = execute(klass, name)
          writer.write(Results.envelope(probe&.capture, result))
          status = 0
        rescue Exception => e # anything: report it, then exit!
          warn "padded_cell: cell #{klass}##{name} failed to report: #{e.class}: #{e.message}"
        ensure
          # exit! skips at_exit handlers: the cell is not the test run.
          exit!(status)
        end
      end
    end

    # [coverage delta or nil, result]
    def collect(pid, reader, klass, name, started, timeout)
      data = read(reader, timeout && (started + timeout))
      elapsed = Minitest.clock_time - started
      if data.nil?
        Process.kill(:KILL, pid)
        Process.wait(pid)
        return [nil, Results.crashed(klass, name, "timed out after #{timeout}s", time: elapsed)]
      end

      _, status = Process.wait2(pid)
      return Results.unwrap(data, klass, name) unless data.empty?

      [nil, Results.crashed(klass, name, Results.describe(status, 'cell'), time: elapsed)]
    end

    # Everything until EOF, or nil when the deadline passes first.
    def read(io, deadline)
      data = String.new(encoding: Encoding::BINARY)
      loop do
        remaining = deadline && (deadline - Minitest.clock_time)
        return if remaining&.<= 0
        next unless io.wait_readable(remaining)

        chunk = io.read_nonblock(CHUNK, exception: false)
        return data if chunk.nil?

        data << chunk if chunk.is_a?(String)
      end
    end
  end
end
