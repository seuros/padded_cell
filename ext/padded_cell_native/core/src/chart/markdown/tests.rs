use std::fs;

use tempfile::TempDir;

use super::super::FileCoverage;
use super::super::test_support::{calc, reports, summary};
use super::*;

/// Calc misses two branches; gap.rb misses a line holding backticks, and
/// one line further down.
#[test]
fn totals_groups_then_the_code_that_never_ran() {
    let dir = TempDir::new().unwrap();
    let gap = dir.path().join("gap.rb");
    fs::write(&gap, "def a\n  1\nend\n\ndef b\n  x = \"```\"\n  :y\nend\n\n:z\n").unwrap();
    let mut lines =
        vec![Some(1), Some(1), None, None, Some(1), Some(0), Some(0), None, None, Some(0)];
    lines.truncate(10);
    let files = [
        calc(&dir),
        FileCoverage {
            path: gap,
            name: "lib/gap.rb".to_owned(),
            lines,
            branches: Some(Vec::new()),
            methods: None,
            loaded: true,
        },
    ];
    let reports = reports(&files);
    let mut summary = summary(&reports, &[Criterion::Line, Criterion::Branch]);
    summary.groups =
        vec![("Core".to_owned(), vec![0], super::super::Totals::of_files(&reports[..1]))];
    summary.meta.project_name = "App".to_owned();
    summary.meta.timestamp = "2026-10-11T13:00:00.000+02:00".to_owned();
    summary.meta.commit = Some("0123456789abcdef".to_owned());
    let mut out = Vec::new();
    write_markdown(&summary, &mut out).unwrap();

    let expected = "\
# Coverage: App

Lines 75.00% (9 / 12) · Branches 50.00% (2 / 4)

Generated 2026-10-11T13:00:00.000+02:00 by padded_cell 0.1.0, at `0123456789ab`.

| Group | Lines | Branches |
|---|---:|---:|
| Core | 100.00% (6 / 6) | 50.00% (2 / 4) |

## Missed, most first

### `lib/gap.rb`

Lines 50.00% (3 / 6) · Branches 100.00% (0 / 0)

Lines never run: 6-7, 10.

````ruby
 6    x = \"```\"
 7    :y
 …
10  :z
````

### `lib/calc.rb`

Lines 100.00% (6 / 6) · Branches 50.00% (2 / 4)

Branches never taken: 7 `else`, 16 `else`.
";
    assert_eq!(String::from_utf8(out).unwrap(), expected);
}

#[test]
fn everything_ran() {
    let dir = TempDir::new().unwrap();
    let mut file = calc(&dir);
    file.branches = None;
    let files = [file];
    let reports = reports(&files);
    let mut out = Vec::new();
    write_markdown(&summary(&reports, &[Criterion::Line]), &mut out).unwrap();
    assert!(
        String::from_utf8(out).unwrap().ends_with("by padded_cell 0.1.0.\n\nEverything ran.\n")
    );
}

#[test]
fn ranges_collapse_runs() {
    assert_eq!(ranges(&[3, 4, 5, 9, 11, 12]), "3-5, 9, 11-12");
    assert_eq!(ranges(&[7]), "7");
}
