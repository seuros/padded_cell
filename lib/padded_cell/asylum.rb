# frozen_string_literal: true

module PaddedCell
  # --asylum: tests that failed get more attempts once the run is over, one
  # at a time, each in a fresh cell. A test that passes on retry counts as
  # passed but is reported as flaky, with every attempt and what changed:
  #
  #   attempt 1, same seed, run alone:  timing, contention, or state left by
  #                                     the tests that ran around it
  #   attempt 2+, another seed:         randomness or test order
  #
  # A test that fails every attempt keeps its first failure.
  class Asylum
    ALONE = 'timing, contention or state left by other tests'
    RESEEDED = 'randomness or test order'
    SEEDS = 2**64

    # The seed of retry attempt, derived from the run's seed so a report can
    # be replayed. Attempt 1 keeps the run's seed. Wraps within the planner's
    # 64-bit seeds, as --seed accepts them.
    def self.retry_seed(seed, attempt)
      attempt == 1 ? seed : (seed + (attempt * 0x9e37)) % SEEDS
    end

    def initialize(tests, attempts:, seed:, limits: Limits.new)
      @tests = tests
      @attempts = attempts
      @seed = seed
      @limits = limits
      @success = true
    end

    # False when a retry's worker failed (its cleanup hook).
    def success? = @success

    # failures: {test index => first failing result}. Yields (index, result)
    # once per test, with its final result. Its metadata holds the attempts:
    # :flaky when it passed on retry, :asylum when it never did. Both are
    # plain data, for Marshal and the JUnit and JSON reports.
    def call(failures)
      history = failures.to_h { |index, result| [index, [attempt_entry(@seed, false, result)]] }
      pending = failures.keys
      1.upto(@attempts) do |attempt|
        break if pending.empty?

        pending -= retry_round(pending, history, attempt) do |index, result|
          result.metadata[:flaky] = flaky(failures[index], history[index], attempt)
          yield index, result
        end
      end
      pending.each do |index|
        failures[index].metadata[:asylum] = { attempts: history[index].size, history: history[index] }
        yield index, failures[index]
      end
    end

    private

    # Runs the pending tests once more, alone; returns the ones that passed.
    def retry_round(pending, history, attempt)
      seed = self.class.retry_seed(@seed, attempt)
      passed = []
      pool = Pool.new(@tests, jobs: 1, isolation: :test, seed:, limits: @limits)
      pool.run([pending.dup]) do |index, result|
        recovered = result.passed? && !result.skipped?
        history[index] << attempt_entry(seed, true, recovered ? nil : result)
        next unless recovered

        passed << index
        yield index, result
      end
      @success &&= pool.success?
      passed
    end

    # One attempt: its seed, whether it ran alone, and how it ended.
    def attempt_entry(seed, alone, failed)
      { seed:, alone:, outcome: failed ? summary(failed.failure)[:message] : 'passed' }
    end

    def flaky(first, history, attempt)
      {
        attempts: history.size, seed: history.last[:seed], cause: attempt == 1 ? ALONE : RESEEDED,
        first_failure: summary(first.failure), history:
      }
    end

    def summary(failure)
      type = failure.is_a?(Minitest::UnexpectedError) ? failure.error.class.name : failure.class.name
      { type:, message: failure.message.lines.first.to_s.strip }
    end
  end
end
