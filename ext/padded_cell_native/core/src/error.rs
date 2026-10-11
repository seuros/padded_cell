use std::path::{Path, PathBuf};
use std::{fs, io};

/// A file that could not be read or written.
#[derive(Debug, thiserror::Error)]
#[error("{}: {source}", path.display())]
pub struct FileError {
    /// The file.
    pub path: PathBuf,
    /// Why it failed.
    #[source]
    pub source: io::Error,
}

impl FileError {
    /// The bytes of `path`.
    ///
    /// # Errors
    ///
    /// A [`FileError`] for `path` when it cannot be read.
    pub fn read(path: &Path) -> Result<Vec<u8>, Self> {
        fs::read(path).map_err(|source| Self { path: path.to_owned(), source })
    }
}
