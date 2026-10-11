use std::fs;

use tempfile::TempDir;

use super::stats::Criterion;
use super::{
    Arm, Condition, FileCoverage, FileReport, Meta, Method, Options, Span, Summary, Totals,
    analyze_all,
};

const CALC: &str = "# frozen_string_literal: true

class Calc
  def sign(number)
    if number.positive?
      :positive
    else
      :other
    end
  end

  # :nocov:
  def debug = puts(1)
  # :nocov:

  def maybe(flag) = flag ? :yes : :no
end
";

pub const fn span(start_line: u32, start_column: u32, end_line: u32, end_column: u32) -> Span {
    Span { start_line, start_column, end_line, end_column }
}

pub fn arm(kind: &str, span: Span, hits: u64) -> Arm {
    Arm { kind: kind.to_owned(), span, hits }
}

pub fn method(name: &str, span: Span, hits: u64) -> Method {
    Method { owner: "Calc".to_owned(), name: name.to_owned(), span, hits }
}

/// Calc, run once with a positive number and once with `maybe(true)`.
pub fn calc(dir: &TempDir) -> FileCoverage {
    let path = dir.path().join("calc.rb");
    fs::write(&path, CALC).unwrap();
    let mut lines = vec![None; 17];
    for (line, hits) in [(3, 1), (4, 1), (5, 2), (6, 1), (8, 1), (13, 1), (16, 1)] {
        lines[line - 1] = Some(hits);
    }
    FileCoverage {
        path,
        name: "lib/calc.rb".to_owned(),
        lines,
        branches: Some(vec![
            Condition {
                kind: "if".to_owned(),
                span: span(5, 4, 9, 7),
                arms: vec![arm("then", span(6, 6, 6, 15), 1), arm("else", span(8, 6, 8, 12), 0)],
            },
            Condition {
                kind: "if".to_owned(),
                span: span(16, 20, 16, 37),
                arms: vec![
                    arm("then", span(16, 27, 16, 31), 1),
                    arm("else", span(16, 34, 16, 37), 0),
                ],
            },
        ]),
        methods: Some(vec![
            method("sign", span(4, 2, 10, 5), 2),
            method("debug", span(13, 2, 13, 21), 0),
            method("maybe", span(16, 2, 16, 37), 1),
        ]),
        loaded: true,
    }
}

/// `files`, analyzed with the default options.
pub fn reports(files: &[FileCoverage]) -> Vec<FileReport<'_>> {
    analyze_all(files, &Options::default()).unwrap()
}

/// A run of `reports`, measuring `measured`, without groups or violations.
pub fn summary<'a>(reports: &'a [FileReport<'a>], measured: &[Criterion]) -> Summary<'a> {
    Summary {
        files: reports,
        measured: measured.to_vec(),
        totals: Totals::of_files(reports),
        groups: Vec::new(),
        violations: Vec::new(),
        meta: Meta { generator: "padded_cell 0.1.0".to_owned(), ..Meta::default() },
    }
}
