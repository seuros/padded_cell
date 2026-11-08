# frozen_string_literal: true

module PaddedCell
  # What cuts a test short: its --timeout, and what is left of the run's
  # --budget. A test's deadline never outlives the run's. Deadlines are
  # PaddedCellNative::Deadline values in monotonic nanoseconds: one clock for
  # the runner, its workers and their cells.
  class Limits
    NS = 1_000_000_000

    def self.now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)

    # Seconds left before deadline (0.0 once passed), nil when never.
    def self.remaining(deadline, now = self.now) = deadline.remaining_ns(now)&./(NS.to_f)

    attr_reader :timeout, :budget

    #   timeout: seconds per test, or nil
    #   budget:  seconds for the whole run from started, or nil
    def initialize(timeout: nil, budget: nil, started: Limits.now)
      @timeout = timeout
      @budget = budget
      @run = budget ? PaddedCellNative::Deadline.after(started, nanoseconds(budget)) : PaddedCellNative::Deadline.never
    end

    # The deadline of a test starting now.
    def for_test(now = Limits.now) = @run.derive(now, @timeout && nanoseconds(@timeout))

    # True once the run's budget is gone: nothing more gets dispatched.
    def spent?(now = Limits.now) = @run.expired?(now)

    # Why a test that reached deadline was cut short.
    def message(deadline)
      if @budget && deadline.expires_at == @run.expires_at
        "run budget of #{@budget}s spent"
      else
        "timed out after #{@timeout}s"
      end
    end

    private

    def nanoseconds(seconds) = (seconds * NS).round
  end
end
