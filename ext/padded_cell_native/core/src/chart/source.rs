use std::ops::RangeInclusive;
use std::path::Path;

use crate::FileError;

#[cfg(test)]
mod tests;

/// A source file split into lines the way Ruby's `readlines` splits it:
/// after each newline, and a last line without one.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Source {
    bytes: Vec<u8>,
    /// Where each line ends, its newline included.
    ends: Vec<usize>,
}

impl Source {
    /// # Errors
    ///
    /// [`FileError`] when the file cannot be read.
    pub fn read(path: &Path) -> Result<Self, FileError> {
        Ok(Self::new(FileError::read(path)?))
    }

    #[must_use]
    pub fn new(bytes: Vec<u8>) -> Self {
        let mut ends: Vec<usize> = newline_ends(&bytes);
        if bytes.last().is_some_and(|&last| last != b'\n') {
            ends.push(bytes.len());
        }
        Self { bytes, ends }
    }

    /// The number of lines.
    #[must_use]
    pub const fn len(&self) -> usize {
        self.ends.len()
    }

    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.ends.is_empty()
    }

    #[must_use]
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    /// The 1-based line and the 0-based byte column of `offset`.
    #[must_use]
    pub fn position(&self, offset: usize) -> (u32, u32) {
        let line = self.ends.partition_point(|&end| end <= offset);
        let number = |value: usize| u32::try_from(value).unwrap_or(u32::MAX);
        (number(line.strict_add(1)), number(offset.strict_sub(self.line_start(offset))))
    }

    /// Where the line holding `offset` starts.
    #[must_use]
    pub fn line_start(&self, offset: usize) -> usize {
        let line = self.ends.partition_point(|&end| end <= offset);
        line.checked_sub(1).map_or(0, |previous| self.ends[previous])
    }

    /// Each line, its newline included.
    pub fn lines(&self) -> impl Iterator<Item = &[u8]> {
        let starts = std::iter::once(0).chain(self.ends.iter().copied());
        starts.zip(&self.ends).map(|(start, &end)| &self.bytes[start..end])
    }

    /// The `# :token:` blocks: from a marker comment to the next, both
    /// included. A block left open runs to the last line.
    #[must_use]
    pub fn nocov(&self, token: &str) -> Vec<RangeInclusive<u32>> {
        let mut markers: Vec<u32> = self
            .lines()
            .zip(1..)
            .filter(|(line, _)| nocov_marker(line, token))
            .map(|(_, n)| n)
            .collect();
        if markers.len() % 2 == 1 {
            markers.push(u32::try_from(self.len()).unwrap_or(u32::MAX));
        }
        markers.as_chunks::<2>().0.iter().map(|&[start, end]| start..=end).collect()
    }

    /// The lines of a file that never loaded, from `Coverage.line_stub`:
    /// blank and comment lines, and lines in `skipped` blocks, are not code.
    #[must_use]
    pub fn relevant(
        &self,
        stub: &[Option<u64>],
        skipped: &[RangeInclusive<u32>],
    ) -> Vec<Option<u64>> {
        let mut lines = self.lines();
        stub.iter()
            .zip(1..)
            .map(|(&hits, number)| {
                let text = lines.next()?;
                let code =
                    !blank_or_comment(text) && !skipped.iter().any(|block| block.contains(&number));
                if code { hits } else { None }
            })
            .collect()
    }
}

/// Without its line ending, as Ruby's `chomp`.
#[must_use]
pub fn chomp(line: &[u8]) -> &[u8] {
    let line = line.strip_suffix(b"\n").unwrap_or(line);
    line.strip_suffix(b"\r").unwrap_or(line)
}

/// Offsets just past each newline.
fn newline_ends(bytes: &[u8]) -> Vec<usize> {
    bytes
        .iter()
        .enumerate()
        .filter(|&(_, &byte)| byte == b'\n')
        .map(|(index, _)| index.strict_add(1))
        .collect()
}

/// Ruby's `\s`: ASCII whitespace only.
pub const fn ruby_space(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | b'\n' | b'\x0b' | b'\x0c' | b'\r')
}

/// Without its leading `\s`.
pub fn trim_start(line: &[u8]) -> &[u8] {
    let start = line.iter().position(|&byte| !ruby_space(byte)).unwrap_or(line.len());
    &line[start..]
}

/// `/^\s*$/` or `/^\s*#/`.
#[must_use]
pub fn blank_or_comment(line: &[u8]) -> bool {
    matches!(trim_start(line).first(), None | Some(b'#'))
}

/// `/^(\s*)#(\s*)(:token:)/`.
fn nocov_marker(line: &[u8], token: &str) -> bool {
    let Some(comment) = trim_start(line).strip_prefix(b"#") else {
        return false;
    };
    let marker = trim_start(comment);
    marker
        .strip_prefix(b":")
        .and_then(|rest| rest.strip_prefix(token.as_bytes()))
        .is_some_and(|rest| rest.starts_with(b":"))
}
