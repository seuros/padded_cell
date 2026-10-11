use tempfile::TempDir;

use super::super::{Meta, Totals};
use super::*;

fn empty() -> Summary<'static> {
    Summary {
        files: &[],
        measured: Vec::new(),
        totals: Totals::default(),
        groups: Vec::new(),
        violations: Vec::new(),
        meta: Meta::default(),
    }
}

#[test]
fn formats_by_name() {
    assert_eq!("lcov".parse(), Ok(Format::Lcov));
    assert_eq!("json".parse(), Ok(Format::Json));
    assert_eq!("html5".parse::<Format>(), Err(UnknownFormat("html5".to_owned())));
}

#[test]
fn writes_into_a_new_directory_without_leftovers() {
    let dir = TempDir::new().unwrap();
    let output = dir.path().join("coverage");
    let written = write(&output, Format::Json, &empty()).unwrap();

    assert_eq!(written, [output.join("coverage.json"), output.join(".resultset.json")]);
    assert_eq!(
        std::fs::read(output.join(".resultset.json")).unwrap(),
        b"{\"padded_cell\":{\"coverage\":{},\"timestamp\":0.0}}\n"
    );
    assert_eq!(std::fs::read_dir(&output).unwrap().count(), 2);
}

#[test]
fn unwritable_directories_are_file_errors() {
    let dir = TempDir::new().unwrap();
    let blocker = dir.path().join("file");
    std::fs::write(&blocker, "").unwrap();
    let error = write(&blocker.join("coverage"), Format::Lcov, &empty()).unwrap_err();
    assert_eq!(error.path, blocker.join("coverage/lcov.info"));
}
