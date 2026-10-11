use std::fs::{self, File};
use std::io::{self, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::str::FromStr;

use super::{
    Summary, write_coverage_json, write_last_run, write_lcov, write_markdown, write_resultset,
};
use crate::FileError;

#[cfg(test)]
mod tests;

/// A report format.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    /// `lcov.info`
    Lcov,
    /// `coverage.json` and `.resultset.json`.
    Json,
    /// `coverage.md`: totals, then the code that never ran.
    Markdown,
}

impl Format {
    /// The files the format writes, in the report directory.
    #[must_use]
    pub const fn file_names(self) -> &'static [&'static str] {
        match self {
            Self::Lcov => &["lcov.info"],
            Self::Json => &["coverage.json", ".resultset.json"],
            Self::Markdown => &["coverage.md"],
        }
    }
}

/// A format name nothing writes.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("unknown coverage format {0:?} (known: markdown, lcov, json)")]
pub struct UnknownFormat(pub String);

impl FromStr for Format {
    type Err = UnknownFormat;

    fn from_str(name: &str) -> Result<Self, UnknownFormat> {
        match name {
            "lcov" => Ok(Self::Lcov),
            "json" => Ok(Self::Json),
            "markdown" => Ok(Self::Markdown),
            _ => Err(UnknownFormat(name.to_owned())),
        }
    }
}

/// Writes `summary` in `format` into `dir`, which it creates; returns the
/// paths written.
///
/// # Errors
///
/// [`FileError`] for the file that could not be written.
pub fn write(dir: &Path, format: Format, summary: &Summary<'_>) -> Result<Vec<PathBuf>, FileError> {
    format
        .file_names()
        .iter()
        .map(|&name| {
            write_file(dir, name, |out| match name {
                "lcov.info" => write_lcov(summary.files, out),
                "coverage.json" => write_coverage_json(summary, out),
                "coverage.md" => write_markdown(summary, out),
                _ => write_resultset(summary, out),
            })
        })
        .collect()
}

/// Writes `.last_run.json`, which the next run's `maximum_drop` reads.
///
/// # Errors
///
/// [`FileError`] when it could not be written.
pub fn write_last_run_file(dir: &Path, summary: &Summary<'_>) -> Result<PathBuf, FileError> {
    write_file(dir, ".last_run.json", |out| write_last_run(summary, out))
}

/// Replaces `dir/name` at once: a reader never sees half a report.
pub(super) fn write_file(
    dir: &Path,
    name: &str,
    render: impl FnOnce(&mut BufWriter<File>) -> io::Result<()>,
) -> Result<PathBuf, FileError> {
    let path = dir.join(name);
    let partial = dir.join(format!(".{name}.partial"));
    let error = |source| FileError { path: path.clone(), source };
    fs::create_dir_all(dir).map_err(error)?;
    let written = File::create(&partial).and_then(|file| {
        let mut out = BufWriter::new(file);
        render(&mut out)?;
        out.flush()?;
        out.into_inner().map_err(io::IntoInnerError::into_error)?.sync_all()
    });
    written.and_then(|()| fs::rename(&partial, &path)).map_err(error)?;
    Ok(path)
}
