use std::io::{self, Write};

#[cfg(test)]
mod tests;

/// A JSON writer. Containers take a closure writing their members:
///
/// ```text
/// json.object(|json| {
///     json.key("lines")?.array(|json| json.item()?.uint(1))
/// })
/// ```
pub struct Json<'w, W: Write> {
    out: &'w mut W,
    pretty: bool,
    depth: usize,
    /// The innermost container has no member yet.
    empty: bool,
}

impl<'w, W: Write> Json<'w, W> {
    /// `JSON.pretty_generate`'s layout: two-space indents, one member per
    /// line, `[]` and `{}` when empty.
    pub const fn pretty(out: &'w mut W) -> Self {
        Self { out, pretty: true, depth: 0, empty: true }
    }

    /// `JSON.generate`'s: no whitespace.
    pub const fn compact(out: &'w mut W) -> Self {
        Self { out, pretty: false, depth: 0, empty: true }
    }

    /// # Errors
    ///
    /// What writing returns.
    pub fn object(&mut self, members: impl FnOnce(&mut Self) -> io::Result<()>) -> io::Result<()> {
        self.container(b'{', b'}', members)
    }

    /// # Errors
    ///
    /// What writing returns.
    pub fn array(&mut self, items: impl FnOnce(&mut Self) -> io::Result<()>) -> io::Result<()> {
        self.container(b'[', b']', items)
    }

    /// Starts an object member: its value comes next.
    ///
    /// # Errors
    ///
    /// What writing returns.
    pub fn key(&mut self, key: &str) -> io::Result<&mut Self> {
        self.separate()?;
        self.raw_str(key)?;
        self.out.write_all(if self.pretty { b": " } else { b":" })?;
        Ok(self)
    }

    /// Starts an array item: its value comes next.
    ///
    /// # Errors
    ///
    /// What writing returns.
    pub fn item(&mut self) -> io::Result<&mut Self> {
        self.separate()?;
        Ok(self)
    }

    /// # Errors
    ///
    /// What writing returns.
    pub fn str(&mut self, value: &str) -> io::Result<()> {
        self.raw_str(value)
    }

    /// # Errors
    ///
    /// What writing returns.
    pub fn uint(&mut self, value: u64) -> io::Result<()> {
        write!(self.out, "{value}")
    }

    /// Ruby's way: `100.0`, not `100`.
    ///
    /// # Errors
    ///
    /// What writing returns.
    pub fn float(&mut self, value: f64) -> io::Result<()> {
        let mut text = value.to_string();
        if !text.contains(['.', 'e', 'N', 'i']) {
            text.push_str(".0");
        }
        self.out.write_all(text.as_bytes())
    }

    /// # Errors
    ///
    /// What writing returns.
    pub fn bool(&mut self, value: bool) -> io::Result<()> {
        self.out.write_all(if value { b"true" } else { b"false" })
    }

    /// # Errors
    ///
    /// What writing returns.
    pub fn null(&mut self) -> io::Result<()> {
        self.out.write_all(b"null")
    }

    fn container(
        &mut self,
        open: u8,
        close: u8,
        members: impl FnOnce(&mut Self) -> io::Result<()>,
    ) -> io::Result<()> {
        self.out.write_all(&[open])?;
        self.depth = self.depth.strict_add(1);
        self.empty = true;
        members(self)?;
        self.depth = self.depth.strict_sub(1);
        if !self.empty {
            self.newline()?;
        }
        // The enclosing container has this one as a member.
        self.empty = false;
        self.out.write_all(&[close])
    }

    fn separate(&mut self) -> io::Result<()> {
        if !self.empty {
            self.out.write_all(b",")?;
        }
        self.empty = false;
        self.newline()
    }

    fn newline(&mut self) -> io::Result<()> {
        if self.pretty {
            self.out.write_all(b"\n")?;
            for _ in 0..self.depth {
                self.out.write_all(b"  ")?;
            }
        }
        Ok(())
    }

    /// Escapes what JSON requires, in runs: no copy of the string.
    fn raw_str(&mut self, value: &str) -> io::Result<()> {
        self.out.write_all(b"\"")?;
        let bytes = value.as_bytes();
        let mut start = 0;
        for (index, &byte) in bytes.iter().enumerate() {
            let escape: &[u8] = match byte {
                b'"' => b"\\\"",
                b'\\' => b"\\\\",
                0x08 => b"\\b",
                0x0c => b"\\f",
                b'\n' => b"\\n",
                b'\r' => b"\\r",
                b'\t' => b"\\t",
                0x20.. => continue,
                _ => b"",
            };
            self.out.write_all(&bytes[start..index])?;
            if escape.is_empty() {
                write!(self.out, "\\u{byte:04x}")?;
            } else {
                self.out.write_all(escape)?;
            }
            start = index.strict_add(1);
        }
        self.out.write_all(&bytes[start..])?;
        self.out.write_all(b"\"")
    }
}
