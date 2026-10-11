use std::assert_matches;
use std::fs;
use std::io::ErrorKind;
use std::path::PathBuf;

use super::*;

fn ids(source: &str) -> Vec<String> {
    ids_of(&discover(source.as_bytes()))
}

#[test]
fn test_classes_are_named_by_their_superclass() {
    let cases: &[(&str, &[&str])] = &[
        ("class ATest < Minitest::Test\n def test_a; end\nend", &["ATest#test_a"]),
        ("class B < ActiveSupport::TestCase\n def test_b; end\nend", &["B#test_b"]),
        ("class C < BaseTest\n def test_c; end\nend", &["C#test_c"]),
        ("class DTest < Object\n def test_d; end\nend", &[]),
        ("class ETest\n def test_e; end\nend", &[]),
        ("class FTest < Testing\n def test_f; end\nend", &[]),
    ];
    for (source, expected) in cases {
        assert_eq!(ids(source), *expected, "source: {source:?}");
    }
}

#[test]
fn rails_test_names_replace_whitespace_runs() {
    // A no-break space is not Ruby's \s: it stays.
    let source = concat!(
        "class ATest < ActiveSupport::TestCase\n",
        "  test \"a \\t\\v\\f\\r\\n b\u{a0}c\" do\n",
        "  end\n",
        "end",
    );
    assert_eq!(ids(source), ["ATest#test_a_b\u{a0}c"]);
}

#[test]
fn lines_are_one_based_and_span_the_definition() {
    let source = "class ATest < Minitest::Test\n\n  def test_a\n    x\n  end\n  test 'b'\nend\n";
    let found = discover(source.as_bytes());
    let lines: Vec<_> = found.iter().map(|test| (test.start_line, test.end_line)).collect();
    assert_eq!(lines, [(3, 5), (6, 6)]);
}

#[test]
fn class_names_are_stored_once_and_only_with_tests() {
    let source = concat!(
        "class BaseTest < Minitest::Test\nend\n",
        "module Admin\n  class ATest < BaseTest\n    def test_a; end\n    test 'b'\n  end\nend\n",
    );
    let found = discover(source.as_bytes());
    assert_eq!(found.classes(), ["Admin::ATest"]);
    assert_eq!(found.iter().map(|test| test.class).collect::<Vec<_>>(), [0, 0]);
    assert_eq!(found.iter().len(), 2);
}

#[test]
fn invalid_utf8_names_are_skipped() {
    let source = "class ATest < Minitest::Test\n  test \"\\xFF\" do\n  end\nend";
    assert_eq!(ids(source), Vec::<String>::new());
}

#[test]
fn discover_many_keeps_input_order() {
    let sources: Vec<String> = (0..64)
        .map(|i| format!("class T{i}Test < Minitest::Test\n def test_{i}; end\nend"))
        .collect();
    let found = discover_many(&sources);
    assert_eq!(found.len(), sources.len());
    for (i, discovery) in found.iter().enumerate() {
        assert_eq!(ids_of(discovery), [format!("T{i}Test#test_{i}")]);
    }
}

#[test]
fn discover_files_keeps_input_order() {
    let dir = tempfile::tempdir().unwrap();
    let paths: Vec<PathBuf> = (0..32)
        .map(|i| {
            let path = dir.path().join(format!("t{i}_test.rb"));
            fs::write(&path, format!("\nclass T{i}Test < Minitest::Test\n  test '{i}'\nend\n"))
                .unwrap();
            path
        })
        .collect();
    let found = discover_files(&paths).unwrap();
    for (i, discovery) in found.iter().enumerate() {
        let tests: Vec<_> = discovery.iter().map(|test| (test.id(), test.start_line)).collect();
        assert_eq!(tests, [(format!("T{i}Test#test_{i}"), 3)]);
    }
}

#[test]
fn discover_files_reports_the_first_unreadable_file() {
    let dir = tempfile::tempdir().unwrap();
    let readable = dir.path().join("a_test.rb");
    fs::write(&readable, "").unwrap();
    let first_missing = dir.path().join("b_test.rb");
    let paths = [readable, first_missing.clone(), dir.path().join("c_test.rb")];
    let error = discover_files(&paths).unwrap_err();
    assert_eq!(error.path, first_missing);
    assert_matches!(error.source.kind(), ErrorKind::NotFound);
}

fn ids_of(discovery: &Discovery) -> Vec<String> {
    discovery.iter().map(|test| test.id()).collect()
}
