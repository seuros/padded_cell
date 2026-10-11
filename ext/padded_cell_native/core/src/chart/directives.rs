use std::ops::RangeInclusive;

use ruby_prism::CommentType;

use super::Source;
use super::source::{ruby_space, trim_start as skip_space};

#[cfg(test)]
mod tests;

/// Blocks of lines, inclusive.
pub type Blocks = Vec<RangeInclusive<u32>>;

/// The lines each criterion ignores.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Skipped {
    pub line: Blocks,
    pub branch: Blocks,
    pub method: Blocks,
}

impl Skipped {
    #[must_use]
    pub fn of(source: &Source, nocov_token: &str) -> Self {
        let nocov = source.nocov(nocov_token);
        let mut skipped = Self { line: nocov.clone(), branch: nocov.clone(), method: nocov };
        // Parsing only sources that may hold one.
        if source.bytes().windows(9).any(|window| window == b"simplecov") {
            skipped.add_directives(source);
        }
        skipped
    }

    fn add_directives(&mut self, source: &Source) {
        let result = ruby_prism::parse(source.bytes());
        let mut open: [Option<u32>; 3] = [None; 3];
        let comments =
            result.comments().filter(|comment| comment.type_() == CommentType::InlineComment);
        for comment in comments {
            let Some((at, directive)) = Directive::find(comment.text()) else {
                continue;
            };
            let offset = comment.location().start_offset().strict_add(at);
            let (line, _) = source.position(offset);
            let before = &source.bytes()[source.line_start(offset)..offset];
            let inline = before.iter().any(|&byte| !ruby_lstrip_space(byte));
            let blocks = self.blocks_mut().into_iter().zip(&mut open);
            for ((blocks, open), _) in blocks.zip(directive.criteria).filter(|&(_, named)| named) {
                directive.apply(line, inline, blocks, open);
            }
        }
        let last = u32::try_from(source.len()).unwrap_or(u32::MAX);
        for (blocks, open) in self.blocks_mut().into_iter().zip(open) {
            blocks.extend(open.map(|start| start..=last));
        }
    }

    const fn blocks_mut(&mut self) -> [&mut Blocks; 3] {
        [&mut self.line, &mut self.branch, &mut self.method]
    }
}

/// A `# simplecov:disable` or `enable`, and the criteria it names: line,
/// branch, method.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Directive {
    disable: bool,
    criteria: [bool; 3],
}

impl Directive {
    /// The first directive in a comment, and where its `#` is:
    /// `/#\s*simplecov\s*:\s*(disable|enable)\b(?:\s+(criteria)\b)?/`.
    fn find(text: &[u8]) -> Option<(usize, Self)> {
        text.iter().enumerate().filter(|&(_, &byte)| byte == b'#').find_map(|(at, _)| {
            Self::parse(&text[at.strict_add(1)..]).map(|directive| (at, directive))
        })
    }

    fn parse(text: &[u8]) -> Option<Self> {
        let text = skip_space(skip_space(text).strip_prefix(b"simplecov")?).strip_prefix(b":")?;
        let text = skip_space(text);
        let (disable, rest) = match text.strip_prefix(b"disable") {
            Some(rest) => (true, rest),
            None => (false, text.strip_prefix(b"enable")?),
        };
        if starts_with_word(rest) {
            return None;
        }
        Some(Self { disable, criteria: criteria(rest).unwrap_or([true; 3]) })
    }

    /// After code, a directive covers its own line; alone on its line, it
    /// opens or closes a block (a block already open stays as it is).
    fn apply(self, line: u32, inline: bool, blocks: &mut Blocks, open: &mut Option<u32>) {
        if inline {
            if self.disable {
                blocks.push(line..=line);
            }
        } else if self.disable {
            open.get_or_insert(line);
        } else if let Some(start) = open.take() {
            blocks.push(start..=line);
        }
    }
}

/// `\s+(line|branch|method)(\s*,\s*(line|branch|method))*\b`, the longest
/// list that ends at a word boundary.
fn criteria(text: &[u8]) -> Option<[bool; 3]> {
    if !text.first().is_some_and(|&byte| ruby_space(byte)) {
        return None;
    }
    let (mut text, mut found, mut accepted) = (skip_space(text), [false; 3], None);
    while let Some((index, rest)) = criterion(text) {
        found[index] = true;
        if starts_with_word(rest) {
            break;
        }
        accepted = Some(found);
        let Some(next) = skip_space(rest).strip_prefix(b",") else {
            break;
        };
        text = skip_space(next);
    }
    accepted
}

fn criterion(text: &[u8]) -> Option<(usize, &[u8])> {
    [&b"line"[..], b"branch", b"method"]
        .iter()
        .enumerate()
        .find_map(|(index, name)| text.strip_prefix(*name).map(|rest| (index, rest)))
}

/// What Ruby's `String#lstrip` strips.
const fn ruby_lstrip_space(byte: u8) -> bool {
    byte == 0 || ruby_space(byte)
}

/// Not at a word boundary: Ruby's `\w` comes next.
fn starts_with_word(text: &[u8]) -> bool {
    text.first().is_some_and(|&byte| byte.is_ascii_alphanumeric() || byte == b'_')
}
