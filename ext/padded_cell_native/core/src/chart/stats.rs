use std::iter::Sum;
use std::ops::{Add, AddAssign};

use super::FileReport;

#[cfg(test)]
mod tests;

/// What coverage counts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Criterion {
    Line,
    Branch,
    Method,
}

impl Criterion {
    /// `line`: its name in `.last_run.json` and in meta keys.
    #[must_use]
    pub const fn singular(self) -> &'static str {
        match self {
            Self::Line => "line",
            Self::Branch => "branch",
            Self::Method => "method",
        }
    }

    /// `lines`: its name in `coverage.json`.
    #[must_use]
    pub const fn plural(self) -> &'static str {
        match self {
            Self::Line => "lines",
            Self::Branch => "branches",
            Self::Method => "methods",
        }
    }
}

/// The counts of one criterion, for a file, a group or a whole run.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    pub covered: u64,
    pub missed: u64,
    /// Lines that are not code (lines only).
    pub omitted: u64,
    /// The hits of the covered items, summed.
    pub hits: u64,
}

impl Stats {
    /// What can be covered.
    #[must_use]
    pub const fn total(&self) -> u64 {
        self.covered.strict_add(self.missed)
    }

    /// Covered, in percent. 100 when nothing was missed, nothing to cover
    /// included.
    #[must_use]
    pub fn percent(&self) -> f64 {
        if self.missed == 0 { 100.0 } else { float(self.covered) * 100.0 / float(self.total()) }
    }

    /// Hits per item that can be covered.
    #[must_use]
    pub fn strength(&self) -> f64 {
        if self.total() == 0 { 0.0 } else { float(self.hits) / float(self.total()) }
    }
}

impl Add for Stats {
    type Output = Self;

    fn add(self, other: Self) -> Self {
        Self {
            covered: self.covered.strict_add(other.covered),
            missed: self.missed.strict_add(other.missed),
            omitted: self.omitted.strict_add(other.omitted),
            hits: self.hits.strict_add(other.hits),
        }
    }
}

impl AddAssign for Stats {
    fn add_assign(&mut self, other: Self) {
        *self = *self + other;
    }
}

impl Sum for Stats {
    fn sum<I: Iterator<Item = Self>>(stats: I) -> Self {
        stats.fold(Self::default(), Add::add)
    }
}

/// The counts of several files: a group, or a whole run. Its percents are
/// computed from the summed counts.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Totals {
    pub line: Stats,
    pub branch: Stats,
    pub method: Stats,
}

impl Totals {
    /// The totals of `files`.
    #[must_use]
    pub fn of_files<'r>(files: impl IntoIterator<Item = &'r FileReport<'r>>) -> Self {
        Self::of(files.into_iter().map(|file| &file.stats.counts))
    }

    #[must_use]
    pub fn of<'r>(files: impl IntoIterator<Item = &'r Self>) -> Self {
        files.into_iter().fold(Self::default(), |totals, file| Self {
            line: totals.line + file.line,
            branch: totals.branch + file.branch,
            method: totals.method + file.method,
        })
    }

    #[must_use]
    pub const fn get(&self, criterion: Criterion) -> Stats {
        match criterion {
            Criterion::Line => self.line,
            Criterion::Branch => self.branch,
            Criterion::Method => self.method,
        }
    }
}

/// The counts of a file.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct FileStats {
    pub counts: Totals,
    /// A file never loaded, without branch data: its branch percent is 0
    /// rather than 100.
    unmeasured_branches: bool,
    unmeasured_methods: bool,
}

impl FileStats {
    pub(super) fn of(report: &FileReport<'_>) -> Self {
        let mut stats = Self {
            unmeasured_branches: !report.file.loaded && report.file.branches.is_none(),
            unmeasured_methods: !report.file.loaded && report.methods.is_none(),
            ..Self::default()
        };
        let counts = &mut stats.counts;
        for line in report.lines() {
            let hits = line.hits.unwrap_or(0);
            count(&mut counts.line, line.covered(), line.missed(), hits);
            counts.line.omitted = counts.line.omitted.strict_add(u64::from(line.never()));
        }
        for branch in report.branches() {
            count(&mut counts.branch, branch.covered(), branch.missed(), branch.hits);
        }
        for method in report.methods() {
            count(&mut counts.method, method.covered(), method.missed(), method.method.hits);
        }
        stats
    }

    #[must_use]
    pub const fn get(&self, criterion: Criterion) -> Stats {
        self.counts.get(criterion)
    }

    /// The counts of `criterion`, and the file's percent.
    #[must_use]
    pub fn with_percent(&self, criterion: Criterion) -> (Stats, f64) {
        (self.get(criterion), self.percent(criterion))
    }

    /// The file's percent.
    #[must_use]
    pub fn percent(&self, criterion: Criterion) -> f64 {
        let unmeasured = match criterion {
            Criterion::Line => false,
            Criterion::Branch => self.unmeasured_branches,
            Criterion::Method => self.unmeasured_methods,
        };
        let stats = self.get(criterion);
        if unmeasured && stats.covered == 0 { 0.0 } else { stats.percent() }
    }
}

const fn count(stats: &mut Stats, covered: bool, missed: bool, hits: u64) {
    if covered {
        stats.covered = stats.covered.strict_add(1);
        stats.hits = stats.hits.strict_add(hits);
    } else if missed {
        stats.missed = stats.missed.strict_add(1);
    }
}

/// Ruby's `Float#floor(2)`, which thresholds compare with:
/// 89.999 is 89.99, and 0.29 stays 0.29 although `0.29 * 100.0` is
/// 28.999999999999996.
#[must_use]
pub fn floor2(number: f64) -> f64 {
    floor_digits(number, 2)
}

/// Ruby's `Float#floor(digits)`: floors `number * 10^digits`, then takes
/// the next step up when it does not exceed `number` (the product lost it).
#[must_use]
pub fn floor_digits(number: f64, digits: i32) -> f64 {
    let scale = 10_f64.powi(digits);
    let floored = (number * scale).floor();
    let up = (floored + 1.0) / scale;
    if up > number { floored / scale } else { up }
}

/// Counts are far below 2^53: the conversion is exact.
#[expect(clippy::cast_precision_loss, reason = "counts stay far below 2^53")]
const fn float(count: u64) -> f64 {
    count as f64
}
