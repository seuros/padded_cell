use std::fs;

use tempfile::TempDir;

use super::test_support::calc;
use super::*;

#[test]
fn lines_branches_and_methods_classified() {
    let dir = TempDir::new().unwrap();
    let file = calc(&dir);
    let report = analyze(&file, &Options::default()).unwrap();

    let skipped: Vec<u32> =
        report.lines().filter(|line| line.skipped).map(|line| line.number).collect();
    assert_eq!(skipped, [12, 13, 14]);
    let branches: Vec<(u32, bool, u64)> = report
        .branches()
        .map(|branch| (branch.report_line(), branch.inline, branch.hits))
        .collect();
    assert_eq!(branches, [(5, false, 1), (7, false, 0), (16, true, 1), (16, true, 0)]);
    let methods: Vec<(&str, bool)> =
        report.methods().map(|method| (method.method.name.as_str(), method.skipped)).collect();
    assert_eq!(methods, [("sign", false), ("debug", true), ("maybe", false)]);

    let stats = report.stats.counts;
    assert_eq!(stats.line, Stats { covered: 6, missed: 0, omitted: 8, hits: 7 });
    assert_eq!(stats.branch, Stats { covered: 2, missed: 2, omitted: 0, hits: 2 });
    assert_eq!(stats.method, Stats { covered: 2, missed: 0, omitted: 0, hits: 3 });
}

#[test]
fn lcov_tracefile_byte_for_byte() {
    let dir = TempDir::new().unwrap();
    let empty = dir.path().join("empty.rb");
    fs::write(&empty, "# nothing\n").unwrap();
    let files = [
        calc(&dir),
        FileCoverage {
            path: empty,
            name: "lib/empty.rb".to_owned(),
            lines: vec![None],
            branches: Some(vec![]),
            methods: None,
            loaded: true,
        },
    ];
    let reports = analyze_all(&files, &Options::default()).unwrap();
    let mut out = Vec::new();
    write_lcov(&reports, &mut out).unwrap();

    let expected = "SF:./lib/calc.rb
DA:3,1
DA:4,1
DA:5,2
DA:6,1
DA:8,1
DA:16,1
LF:7
LH:6
BRDA:5,0,1,1
BRDA:7,0,2,-
BRDA:16,0,3,1
BRDA:16,0,4,-
end_of_record
SF:./lib/empty.rb

LF:0
LH:0

end_of_record
";
    assert_eq!(String::from_utf8(out).unwrap(), expected);
}

#[test]
fn files_never_loaded_count_their_code_as_missed() {
    let dir = TempDir::new().unwrap();
    let mut file = calc(&dir);
    file.loaded = false;
    file.lines = vec![Some(0); 17];
    file.branches = None;
    file.methods = None;
    let report = analyze(&file, &Options::default()).unwrap();

    assert_eq!(report.stats.counts.line, Stats { covered: 0, missed: 10, omitted: 4, hits: 0 });
    assert_eq!(report.stats.percent(Criterion::Branch).to_bits(), 0.0_f64.to_bits());
}

#[test]
fn unreadable_sources_are_file_errors() {
    let dir = TempDir::new().unwrap();
    let mut file = calc(&dir);
    file.path = dir.path().join("missing.rb");
    let error = analyze(&file, &Options::default()).unwrap_err();
    assert_eq!(error.path, file.path);
}
