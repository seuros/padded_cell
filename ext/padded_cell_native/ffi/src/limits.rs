//! What bounds a run: `PaddedCellNative::Deadline` (`--timeout` and
//! `--budget`) and `PaddedCellNative::Restarts` (dead workers). Times are
//! monotonic nanoseconds, the same clock in the runner, its workers and their
//! cells.

use std::cell::RefCell;

use deadline_machines::{Deadline, Instant};
use magnus::{Error, Module, Object, RModule, Ruby, function, method};
use padded_cell::Restarts;

/// A point in monotonic time past which a test (or the run) is cut short, or
/// never.
#[magnus::wrap(class = "PaddedCellNative::Deadline", free_immediately, size, frozen_shareable)]
struct RbDeadline(Deadline);

impl RbDeadline {
    const fn after(now_ns: u64, ns: u64) -> Self {
        Self(Deadline::after(Instant(now_ns), ns))
    }

    const fn never() -> Self {
        Self(Deadline::never())
    }

    /// `timeout_ns` from `now_ns`, never past this deadline; nil: this one.
    fn derive(&self, now_ns: u64, timeout_ns: Option<u64>) -> Self {
        Self(timeout_ns.map_or(self.0, |ns| self.0.derive(Instant(now_ns), ns)))
    }

    /// Nanoseconds left (0 once expired), nil when never.
    const fn remaining_ns(&self, now_ns: u64) -> Option<u64> {
        self.0.remaining_ns(Instant(now_ns))
    }

    const fn is_expired(&self, now_ns: u64) -> bool {
        self.0.is_expired(Instant(now_ns))
    }

    /// Monotonic nanoseconds, nil when never.
    fn expires_at(&self) -> Option<u64> {
        self.0.expires_at().map(|at| at.0)
    }
}

#[magnus::wrap(class = "PaddedCellNative::Restarts", free_immediately, size)]
struct RbRestarts(RefCell<Restarts>);

impl RbRestarts {
    fn new(jobs: usize) -> Self {
        Self(RefCell::new(Restarts::new(jobs)))
    }

    /// True to replace the dead worker, false to give up.
    fn died(&self, now_ns: u64) -> bool {
        self.0.borrow_mut().died(now_ns)
    }

    fn limit(&self) -> u32 {
        self.0.borrow().limit()
    }

    const fn window_ns() -> u64 {
        padded_cell::restarts::WINDOW_NS
    }
}

pub fn define(ruby: &Ruby, module: RModule) -> Result<(), Error> {
    let deadline = module.define_class("Deadline", ruby.class_object())?;
    deadline.define_singleton_method("after", function!(RbDeadline::after, 2))?;
    deadline.define_singleton_method("never", function!(RbDeadline::never, 0))?;
    deadline.define_method("derive", method!(RbDeadline::derive, 2))?;
    deadline.define_method("remaining_ns", method!(RbDeadline::remaining_ns, 1))?;
    deadline.define_method("expired?", method!(RbDeadline::is_expired, 1))?;
    deadline.define_method("expires_at", method!(RbDeadline::expires_at, 0))?;

    let restarts = module.define_class("Restarts", ruby.class_object())?;
    restarts.define_singleton_method("new", function!(RbRestarts::new, 1))?;
    restarts.define_singleton_method("window_ns", function!(RbRestarts::window_ns, 0))?;
    restarts.define_method("died", method!(RbRestarts::died, 1))?;
    restarts.define_method("limit", method!(RbRestarts::limit, 0))?;
    Ok(())
}
