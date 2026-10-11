mod directives;
mod json;
mod lcov;
mod markdown;
mod methods;
mod output;
mod results;
mod source;
mod stats;
mod thresholds;

#[cfg(test)]
mod test_support;
#[cfg(test)]
mod tests;

use std::borrow::Cow;
use std::ops::RangeInclusive;
use std::path::PathBuf;

pub use directives::{Blocks, Skipped};
pub use json::Json;
pub use lcov::write_lcov;
pub use markdown::write_markdown;
pub use methods::static_methods;
pub use output::{Format, UnknownFormat, write, write_last_run_file};
pub use results::{Meta, Summary, write_coverage_json, write_last_run, write_resultset};
pub use source::{Source, chomp};
pub use stats::{Criterion, FileStats, Stats, Totals, floor_digits, floor2};
pub use thresholds::{CRITERIA, Limits, Scope, Thresholds, Violation, violations};

use crate::FileError;
use crate::parallel::fill;

/// A range of source: 1-based lines, 0-based columns, as Ruby reports them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub start_line: u32,
    pub start_column: u32,
    pub end_line: u32,
    pub end_column: u32,
}

impl Span {
    const fn overlaps(&self, lines: &RangeInclusive<u32>) -> bool {
        self.start_line <= *lines.end() && self.end_line >= *lines.start()
    }
}

/// One way through a [`Condition`]: `then`, `else`, `when`, `in`, `body`...
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Arm {
    pub kind: String,
    pub span: Span,
    pub hits: u64,
}

/// A branching construct (`if`, `unless`, `case`, `while`, `&.`...) and its
/// arms.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Condition {
    pub kind: String,
    pub span: Span,
    pub arms: Vec<Arm>,
}

/// A method definition, and how many times it was called.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Method {
    /// The class or module it was defined in, as Ruby names it.
    pub owner: String,
    pub name: String,
    pub span: Span,
    pub hits: u64,
}

/// What was measured for one file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileCoverage {
    /// Where to read the source.
    pub path: PathBuf,
    /// The path reports show: relative to the project root.
    pub name: String,
    /// Hits by line, index 0 for line 1; `None` where there is no code.
    pub lines: Vec<Option<u64>>,
    /// `None` when branches were not measured for this file.
    pub branches: Option<Vec<Condition>>,
    /// `None` when methods were not measured for this file.
    pub methods: Option<Vec<Method>>,
    /// False for a tracked file the suite never loaded: Ruby compiled it
    /// without running it. Blank and comment lines are dropped from its
    /// lines, and its methods (which only exist once run) are found in its
    /// source.
    pub loaded: bool,
}

/// How sources are read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Options {
    /// The word between colons that opens and closes a block of lines
    /// coverage ignores: `# :nocov:`.
    pub nocov_token: String,
    /// Methods were measured: files never loaded get theirs from the source.
    pub methods: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self { nocov_token: "nocov".to_owned(), methods: false }
    }
}

/// A file, read and classified.
#[derive(Debug)]
pub struct FileReport<'a> {
    pub file: &'a FileCoverage,
    pub source: Source,
    pub stats: FileStats,
    lines: Cow<'a, [Option<u64>]>,
    methods: Option<Cow<'a, [Method]>>,
    skipped: Skipped,
}

/// A source line and its coverage.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Line<'r> {
    pub number: u32,
    pub text: &'r [u8],
    /// `None` where there is no code. A skipped line keeps its hits.
    pub hits: Option<u64>,
    pub skipped: bool,
}

impl Line<'_> {
    /// Not code.
    #[must_use]
    pub const fn never(&self) -> bool {
        !self.skipped && self.hits.is_none()
    }

    #[must_use]
    pub const fn covered(&self) -> bool {
        !self.skipped && matches!(self.hits, Some(hits) if hits > 0)
    }

    /// Code that never ran.
    #[must_use]
    pub const fn missed(&self) -> bool {
        !self.skipped && matches!(self.hits, Some(0))
    }
}

/// An arm of a condition, as reports show it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Branch<'r> {
    pub kind: &'r str,
    pub start_line: u32,
    pub end_line: u32,
    pub hits: u64,
    /// The arm starts on the line of its condition (`x ? a : b`).
    pub inline: bool,
    pub skipped: bool,
    /// Where its condition starts.
    pub condition_line: u32,
}

impl Branch<'_> {
    /// The line a branch is shown on: its own when inline, else the line
    /// before it (the `if` or `else` above a block).
    #[must_use]
    pub const fn report_line(&self) -> u32 {
        if self.inline { self.start_line } else { self.start_line.saturating_sub(1) }
    }

    #[must_use]
    pub const fn covered(&self) -> bool {
        !self.skipped && self.hits > 0
    }

    #[must_use]
    pub const fn missed(&self) -> bool {
        !self.skipped && self.hits == 0
    }
}

/// A method and its coverage.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MethodReport<'r> {
    pub method: &'r Method,
    pub skipped: bool,
}

impl MethodReport<'_> {
    #[must_use]
    pub const fn covered(&self) -> bool {
        !self.skipped && self.method.hits > 0
    }

    #[must_use]
    pub const fn missed(&self) -> bool {
        !self.skipped && self.method.hits == 0
    }
}

/// Reads `file`'s source and classifies what was measured.
///
/// # Errors
///
/// [`FileError`] when the source cannot be read.
pub fn analyze<'a>(file: &'a FileCoverage, options: &Options) -> Result<FileReport<'a>, FileError> {
    let source = Source::read(&file.path)?;
    let skipped = Skipped::of(&source, &options.nocov_token);
    let lines = if file.loaded {
        Cow::Borrowed(file.lines.as_slice())
    } else {
        Cow::Owned(source.relevant(&file.lines, &skipped.line))
    };
    let methods = match &file.methods {
        Some(methods) => Some(Cow::Borrowed(methods.as_slice())),
        None if !file.loaded && options.methods => static_methods(&source).map(Cow::Owned),
        None => None,
    };
    let mut report =
        FileReport { file, source, stats: FileStats::default(), lines, methods, skipped };
    report.stats = FileStats::of(&report);
    Ok(report)
}

/// [`analyze`] for every file, spread over the available cores. Reports keep
/// the order of `files`.
///
/// # Errors
///
/// The [`FileError`] of the first unreadable source, in input order.
pub fn analyze_all<'a>(
    files: &'a [FileCoverage],
    options: &Options,
) -> Result<Vec<FileReport<'a>>, FileError> {
    let mut reports: Vec<Option<FileReport<'a>>> = files.iter().map(|_| None).collect();
    fill(files, &mut reports, |file| analyze(file, options).map(Some))?;
    Ok(reports.into_iter().flatten().collect())
}

impl<'a> FileReport<'a> {
    /// Hits by line, as measured (index 0 for line 1): for a file never
    /// loaded, its code lines only.
    #[must_use]
    pub fn raw_lines(&self) -> &[Option<u64>] {
        &self.lines
    }

    /// Every line of the source, in order.
    pub fn lines(&self) -> impl Iterator<Item = Line<'_>> {
        self.source.lines().zip(1..).enumerate().map(|(index, (text, number))| Line {
            number,
            text,
            hits: self.lines.get(index).copied().flatten(),
            skipped: self.skipped.line.iter().any(|block| block.contains(&number)),
        })
    }

    /// Every arm of every condition, in Ruby's order. Empty when branches
    /// were not measured.
    pub fn branches(&self) -> impl Iterator<Item = Branch<'a>> + '_ {
        self.file.branches.iter().flatten().flat_map(move |condition| {
            condition.arms.iter().map(move |arm| {
                let inline = arm.span.start_line == condition.span.start_line;
                let mut branch = Branch {
                    kind: &arm.kind,
                    start_line: arm.span.start_line,
                    end_line: arm.span.end_line,
                    hits: arm.hits,
                    inline,
                    skipped: false,
                    condition_line: condition.span.start_line,
                };
                branch.skipped =
                    self.skipped.branch.iter().any(|block| {
                        arm.span.overlaps(block) || block.contains(&branch.report_line())
                    });
                branch
            })
        })
    }

    /// The branches outside skipped blocks: what reports show.
    pub fn reported_branches(&self) -> impl Iterator<Item = Branch<'a>> + '_ {
        self.branches().filter(|branch| !branch.skipped)
    }

    /// Every method, in the order measured. Empty when methods were not
    /// measured.
    pub fn methods(&self) -> impl Iterator<Item = MethodReport<'_>> {
        let lines = self.source.len();
        self.methods.iter().flat_map(|methods| methods.iter()).map(move |method| MethodReport {
            method,
            // A method past the end of the source has no lines to show.
            skipped: usize::try_from(method.span.start_line).is_ok_and(|start| start > lines)
                || self.skipped.method.iter().any(|block| method.span.overlaps(block)),
        })
    }
}
