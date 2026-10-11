use tempfile::TempDir;

use super::super::test_support::{calc, reports};
use super::*;

/// Calc: lines 100% (6/6), branches 50% (2/4).
#[test]
fn every_kind_of_threshold() {
    let dir = TempDir::new().unwrap();
    let files = [calc(&dir)];
    let reports = reports(&files);
    let totals = Totals::of_files(&reports);
    let thresholds = Thresholds {
        minimum: [Some(100.0), Some(60.0), Some(100.0)],
        minimum_by_file: [None, Some(50.01), None],
        minimum_by_group: vec![("Core".to_owned(), [Some(100.0), Some(49.99), None])],
        maximum_drop: [Some(0.0), Some(5.0), None],
        last_run: [Some(100.0), Some(60.0), None],
    };
    let groups = [("Core".to_owned(), totals), ("Other".to_owned(), Totals::default())];
    let found =
        violations(&thresholds, &[Criterion::Line, Criterion::Branch], &totals, &reports, &groups);

    let violation =
        |scope, limit, actual| Violation { scope, criterion: Criterion::Branch, limit, actual };
    assert_eq!(
        found,
        [
            violation(Scope::Total, 60.0, 50.0),
            violation(Scope::File("lib/calc.rb".to_owned()), 50.01, 50.0),
            // Dropped from 60% to 50%: more than 5 points. Methods were not
            // measured: their minimum is not checked.
            violation(Scope::Drop, 5.0, 10.0),
        ]
    );
}
