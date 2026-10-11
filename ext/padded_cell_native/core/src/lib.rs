//! Static Minitest discovery and deterministic test scheduling: the engine
//! of the [padded_cell](https://github.com/seuros/padded_cell) test runner.
//!
//! ```
//! let source = b"class UserTest < Minitest::Test\n  def test_valid\n  end\nend\n";
//! let found = padded_cell::discover(source);
//! let test = found.iter().next().ok_or("no test")?;
//! assert_eq!(test.id(), "UserTest#test_valid");
//! assert_eq!((test.start_line, test.end_line), (2, 3));
//!
//! let classes: Vec<&str> = found.iter().map(|test| test.class_name).collect();
//! assert_eq!(padded_cell::plan(&classes, &[-1.0], 42, 0, 1), [vec![0]]);
//! # Ok::<(), Box<dyn std::error::Error>>(())
//! ```

pub mod chart;
mod discover;
mod error;
mod hash;
mod parallel;
mod plan;
mod rng;

pub use discover::{
    Discovery, Iter, TestDef, discover, discover_file, discover_files, discover_many,
};
pub use error::FileError;
pub use hash::fnv1a64;
pub use plan::plan;
pub use rng::SplitMix64;

#[cfg(doctest)]
#[doc = include_str!("../README.md")]
struct ReadmeDoctests;
