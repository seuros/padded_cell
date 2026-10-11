use tempfile::TempDir;

use super::super::FileCoverage;
use super::super::test_support::{calc, reports, summary};
use super::*;

fn render(file: &FileCoverage, measured: &[Criterion], write: WriteFn) -> String {
    let files = [file.clone()];
    let reports = reports(&files);
    let mut summary = summary(&reports, measured);
    summary.groups = vec![("Core".to_owned(), vec![0], summary.totals)];
    summary.violations = vec![Violation {
        scope: Scope::File("lib/calc.rb".to_owned()),
        criterion: Criterion::Branch,
        limit: 60.0,
        actual: 50.0,
    }];
    summary.meta = Meta {
        root: "/app".to_owned(),
        timestamp: "2026-10-11T13:00:00.000+02:00".to_owned(),
        created_at: 1_791_716_400.5,
        commit: None,
        project_name: "App".to_owned(),
        generator: "padded_cell 0.1.0".to_owned(),
    };
    let mut out = Vec::new();
    write(&summary, &mut out).unwrap();
    String::from_utf8(out).unwrap()
}

type WriteFn = fn(&Summary<'_>, &mut Vec<u8>) -> io::Result<()>;

#[test]
fn last_run_holds_the_floored_percents_measured() {
    let dir = TempDir::new().unwrap();
    let rendered = render(&calc(&dir), &[Criterion::Line, Criterion::Branch], write_last_run);
    assert_eq!(
        rendered,
        "{\n  \"result\": {\n    \"line\": 100.0,\n    \"branch\": 50.0\n  }\n}\n"
    );
}

/// Keys as Ruby's `Array#to_s` writes them; ids numbered in compile order.
#[test]
fn resultset_keys_are_rubys() {
    let dir = TempDir::new().unwrap();
    let measured = [Criterion::Line, Criterion::Branch, Criterion::Method];
    let rendered = render(&calc(&dir), &measured, write_resultset);
    for expected in [
        r#"{"padded_cell":{"coverage":{""#,
        r#"/calc.rb":{"lines":[null,null,1,1,2,1,null,1,null,null,null,null,1,null,null,1,null],"#,
        concat!(
            r#""branches":{"[:if, 0, 5, 4, 9, 7]":"#,
            r#"{"[:then, 1, 6, 6, 6, 15]":1,"[:else, 2, 8, 6, 8, 12]":0},"#,
        ),
        r#""[:if, 3, 16, 20, 16, 37]":{"[:then, 4, 16, 27, 16, 31]":1,"#,
        r#""methods":{"[Calc, :sign, 4, 2, 10, 5]":2,"#,
        r#""timestamp":1791716400.5}}"#,
    ] {
        assert!(rendered.contains(expected), "{expected} in {rendered}");
    }
    assert_eq!(ruby_symbol("&."), r#":"&.""#);
    assert_eq!(ruby_symbol("empty?"), ":empty?");
}

#[test]
fn coverage_json_sections() {
    let dir = TempDir::new().unwrap();
    let rendered = render(&calc(&dir), &[Criterion::Line, Criterion::Branch], |s, o| {
        write_coverage_json(s, o)
    });
    for expected in [
        &format!("  \"$schema\": \"{SCHEMA}\",\n"),
        "    \"simplecov_version\": \"padded_cell 0.1.0\",\n",
        "    \"commit\": null,\n",
        "    \"method_coverage\": false\n",
        "      \"source\": [\n        \"# frozen_string_literal: true\",\n",
        "        \"ignored\",\n",
        concat!(
            "          \"type\": \"else\",\n          \"start_line\": 8,\n",
            "          \"end_line\": 8,\n          \"coverage\": 0,\n",
            "          \"inline\": false,\n          \"report_line\": 7\n",
        ),
        "      \"branches_covered_percent\": 50.0,\n",
        "    \"Core\": {\n      \"lines\": {\n",
        "      \"files\": [\n        \"lib/calc.rb\"\n      ]\n",
        concat!(
            "  \"errors\": {\n    \"minimum_coverage_by_file\": {\n",
            "      \"lib/calc.rb\": {\n        \"branches\": {\n",
            "          \"expected\": 60.0,\n          \"actual\": 50.0\n",
        ),
    ] {
        assert!(rendered.contains(expected), "{expected:?} in {rendered}");
    }
    assert!(!rendered.contains("\"methods\""), "methods were not measured");
}
