# frozen_string_literal: true

module PaddedCell
  # Raised (in a result, never for real) for a test that did not report:
  # its process crashed, exited or timed out.
  class CellCrashed < StandardError; end

  # Minitest::Result helpers.
  module Results
    module_function

    # An error result for a test that never reported.
    def crashed(klass, name, message, time: 0.0)
      result = Minitest::Result.new(name)
      result.klass = klass.name
      result.time = time
      result.source_location = source_location(klass, name)
      error = CellCrashed.new(message)
      error.set_backtrace(["#{result.source_location.join(':')}:in '#{klass}##{name}'"])
      result.failures = [Minitest::UnexpectedError.new(error)]
      result
    end

    # Why a process ended without reporting.
    def describe(status, process)
      return "#{process} killed by SIG#{Signal.signame(status.termsig)}" if status.signaled?

      "#{process} exited with status #{status.exitstatus} before reporting"
    end

    MISSING_CONSTANT = %r{\Aundefined class/module (\S+)\z}
    # Nesting deeper than this is not a result anyone wrote.
    PLACEHOLDER_LIMIT = 32

    # A result from a worker or cell, or an error result for klass#name when
    # it cannot be loaded. Never raises: one bad result must not end the run.
    #
    # The sender may have loaded classes after it was forked (an error class
    # Rails autoloads during a test, a class a test defines): placeholders
    # named like them stand in during the load, then are removed again, so
    # the failure keeps its class name, message and backtrace.
    def load(payload, klass, name)
      placeholders = []
      begin
        Marshal.load(payload) # written by our own worker or cell
      rescue ArgumentError => e
        missing = MISSING_CONSTANT.match(e.message)&.[](1)
        raise unless missing && placeholders.size < PLACEHOLDER_LIMIT && placeholder(missing, placeholders)

        retry
      end
    rescue StandardError => e
      crashed(klass, name, "its result could not be loaded: #{e.class}: #{e.message}")
    ensure
      placeholders.reverse_each { |owner, constant| owner.send(:remove_const, constant) }
    end

    # Defines the first missing constant of path (a module on the way, an
    # error class at the end). False when path cannot be made to exist.
    def placeholder(path, placeholders)
      owner = Object
      *namespaces, last = path.split('::')
      namespaces.each do |segment|
        unless owner.const_defined?(segment, false)
          owner.const_set(segment, Module.new)
          return placeholders << [owner, segment]
        end
        owner = owner.const_get(segment, false)
        return false unless owner.is_a?(Module)
      end
      return false if owner.const_defined?(last, false)

      owner.const_set(last, Class.new(StandardError))
      placeholders << [owner, last]
    end

    # What a cell sends its worker: its coverage delta (nil without
    # coverage) beside its result. The outer layer holds only core types, so
    # it loads even when the result does not.
    def envelope(delta, result) = Marshal.dump([delta, dump(result)])

    # [delta, result] from an envelope; never raises.
    def unwrap(data, klass, name)
      delta, payload = Marshal.load(data) # written by our own cell
      [delta, load(payload, klass, name)]
    rescue StandardError => e
      [nil, crashed(klass, name, "its result could not be loaded: #{e.class}: #{e.message}")]
    end

    # Marshal.dump, after replacing failures that cannot cross a pipe (an
    # exception holding a Proc, an IO...) with plain copies.
    def dump(result)
      Marshal.dump(result)
    rescue TypeError, ArgumentError
      result.failures = result.failures.map { portable(it) }
      result.metadata = {} if result.metadata?
      Marshal.dump(result)
    end

    def portable(failure)
      Marshal.dump(failure)
      failure
    rescue TypeError, ArgumentError
      error = failure.is_a?(Minitest::UnexpectedError) ? failure.error : failure
      message = "#{error.class}: #{error.message}"
      copy = case failure
             when Minitest::UnexpectedError then Minitest::UnexpectedError.new(RuntimeError.new(message))
             when Minitest::Skip then Minitest::Skip.new(error.message)
             else Minitest::Assertion.new(message)
             end
      (copy.is_a?(Minitest::UnexpectedError) ? copy.error : copy).set_backtrace(error.backtrace || [])
      copy
    end

    def source_location(klass, name)
      klass.instance_method(name).source_location || ['unknown', -1]
    rescue NameError
      ['unknown', -1]
    end
  end
end
