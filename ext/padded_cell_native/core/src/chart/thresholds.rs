use super::stats::{Criterion, Totals, floor_digits};
use super::{FileReport, floor2};

#[cfg(test)]
mod tests;

/// A limit per criterion: line, branch, method.
pub type Limits = [Option<f64>; 3];

pub const CRITERIA: [Criterion; 3] = [Criterion::Line, Criterion::Branch, Criterion::Method];

/// What a run must reach.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Thresholds {
    /// The whole run.
    pub minimum: Limits,
    /// Every file.
    pub minimum_by_file: Limits,
    /// Groups, by name.
    pub minimum_by_group: Vec<(String, Limits)>,
    /// How far coverage may fall since the previous run (`.last_run.json`).
    pub maximum_drop: Limits,
    /// The previous run's percents.
    pub last_run: Limits,
}

/// Where a threshold was missed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Scope {
    Total,
    File(String),
    Group(String),
    /// Coverage fell since the previous run.
    Drop,
}

/// A threshold missed. For a drop, `limit` is the maximum and `actual` the
/// drop; otherwise `limit` is the minimum and `actual` the percent.
#[derive(Debug, Clone, PartialEq)]
pub struct Violation {
    pub scope: Scope,
    pub criterion: Criterion,
    pub limit: f64,
    pub actual: f64,
}

/// Every threshold `totals`, `files` and `groups` miss, for the criteria
/// `measured`.
#[must_use]
pub fn violations(
    thresholds: &Thresholds,
    measured: &[Criterion],
    totals: &Totals,
    files: &[FileReport<'_>],
    groups: &[(String, Totals)],
) -> Vec<Violation> {
    let mut found = Vec::new();
    let total = |criterion| totals.get(criterion).percent();
    below(&mut found, || Scope::Total, &thresholds.minimum, measured, total);
    for file in files {
        let scope = || Scope::File(file.file.name.clone());
        below(&mut found, scope, &thresholds.minimum_by_file, measured, |c| file.stats.percent(c));
    }
    for (name, limits) in &thresholds.minimum_by_group {
        if let Some((_, group)) = groups.iter().find(|(group, _)| group == name) {
            let scope = || Scope::Group(name.clone());
            below(&mut found, scope, limits, measured, |criterion| group.get(criterion).percent());
        }
    }
    for (criterion, maximum) in limits_of(&thresholds.maximum_drop, measured) {
        let Some(previous) = thresholds.last_run[index(criterion)] else {
            continue;
        };
        let drop = floor_digits(previous - floor2(totals.get(criterion).percent()), 10);
        if drop > maximum {
            found.push(Violation { scope: Scope::Drop, criterion, limit: maximum, actual: drop });
        }
    }
    found
}

/// The percents, floored, under their minimum.
fn below(
    found: &mut Vec<Violation>,
    scope: impl Fn() -> Scope,
    limits: &Limits,
    measured: &[Criterion],
    percent: impl Fn(Criterion) -> f64,
) {
    for (criterion, limit) in limits_of(limits, measured) {
        let actual = floor2(percent(criterion));
        if actual < limit {
            found.push(Violation { scope: scope(), criterion, limit, actual });
        }
    }
}

/// The limits set, for the criteria measured.
fn limits_of<'l>(
    limits: &'l Limits,
    measured: &'l [Criterion],
) -> impl Iterator<Item = (Criterion, f64)> + 'l {
    CRITERIA
        .into_iter()
        .zip(limits)
        .filter(|(criterion, _)| measured.contains(criterion))
        .filter_map(|(criterion, limit)| limit.map(|limit| (criterion, limit)))
}

const fn index(criterion: Criterion) -> usize {
    match criterion {
        Criterion::Line => 0,
        Criterion::Branch => 1,
        Criterion::Method => 2,
    }
}
