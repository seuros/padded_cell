//! When to stop replacing dead workers.
//!
//! A worker that dies takes its test with it and gets replaced; a worker
//! that keeps dying (a boot that segfaults, an `after_fork` hook that exits)
//! would otherwise turn every remaining test into a crash report, one fork
//! at a time.
//!
//! The decision is [`supervisor_machines`]'s: one-for-one, restart
//! intensity over a sliding window. Spawning, killing and reaping stay with
//! the caller.

use supervisor_machines::{Decision, Exit, Intensity, Policy, Strategy, Supervisor};

#[cfg(test)]
mod tests;

/// Restart timestamps kept: bounds [`Restarts::limit`].
const HISTORY: usize = 1024;

/// Deaths allowed per worker inside one window, before giving up.
const PER_WORKER: u32 = 4;

/// Deaths allowed inside one window whatever the worker count: a few tests
/// that kill their worker are what cells and workers exist to contain.
const FLOOR: u32 = 16;

/// The sliding window, in nanoseconds.
pub const WINDOW_NS: u64 = 10_000_000_000;

/// Worker deaths seen by one pool.
#[derive(Debug, Clone)]
pub struct Restarts {
    supervisor: Supervisor<1, HISTORY>,
}

impl Restarts {
    /// For a pool of `jobs` workers: `4 * jobs` deaths per 10 seconds, at
    /// least 16.
    #[must_use]
    pub fn new(jobs: usize) -> Self {
        let jobs = u32::try_from(jobs).unwrap_or(u32::MAX);
        let limit = jobs.saturating_mul(PER_WORKER).clamp(FLOOR, HISTORY_LIMIT);
        Self { supervisor: Supervisor::new(Strategy::OneForOne, Intensity::new(limit, WINDOW_NS)) }
    }

    /// A worker died at `now_ns` (monotonic): true to replace it, false to
    /// give up. Once false, always false.
    pub const fn died(&mut self, now_ns: u64) -> bool {
        matches!(
            self.supervisor.stopped(0, Policy::Permanent, Exit::Abnormal, now_ns),
            Decision::Restart(_)
        )
    }

    /// Deaths allowed inside [`WINDOW_NS`].
    #[must_use]
    pub const fn limit(&self) -> u32 {
        self.supervisor.intensity().restarts
    }
}

/// The history must hold one more death than the limit to see it exceeded.
#[expect(clippy::cast_possible_truncation, reason = "HISTORY is 1024")]
const HISTORY_LIMIT: u32 = HISTORY as u32 - 1;
