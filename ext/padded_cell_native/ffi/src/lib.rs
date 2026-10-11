//! Ruby bindings for the `padded_cell` crate. Only primitives cross: each
//! function mirrors a `PaddedCell::Engine` method; the runner is the only
//! caller, so arguments are trusted.
//!
//! Nothing is copied twice: Ruby strings are read in place (see
//! `with_bytes`), files are read by Rust, and results are written straight
//! into Ruby objects.
#![expect(
    clippy::needless_pass_by_value,
    reason = "magnus converts Ruby arguments into owned values; every function takes them"
)]

use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

use magnus::prelude::*;
use magnus::{Error, RArray, RString, Ruby, function};
use padded_cell::{Discovery, FileError};

mod chart;

/// `Errno::*` for the path, as Ruby's own file reading raises.
fn file_error(ruby: &Ruby, error: &FileError) -> Error {
    let path = error.path.display().to_string();
    let Some(errno) = error.source.raw_os_error() else {
        return Error::new(ruby.exception_io_error(), error.to_string());
    };
    match ruby.exception_system_call_error().new_instance((path, errno)) {
        Ok(exception) => exception.into(),
        Err(error) => error,
    }
}

/// The strings of a Ruby array. They stay reachable for the GC through the
/// array, a Ruby argument.
fn strings(array: RArray) -> Result<Vec<RString>, Error> {
    (0..array.len()).map(|index| array.entry(index.cast_signed())).collect()
}

/// Lends `f` the bytes of Ruby strings, without copying them.
///
/// Only call it with closures that run pure Rust (the `padded_cell` crate):
/// see the SAFETY comment.
#[expect(unsafe_code, reason = "reads Ruby strings in place instead of copying them")]
fn with_bytes<R>(strings: &[RString], f: impl FnOnce(&[&[u8]]) -> R) -> R {
    // SAFETY: `RString::as_slice` requires that Ruby neither frees, moves nor
    // modifies the strings while the slices live. The slices only live
    // during `f`, which runs Rust code that never calls into Ruby: it
    // allocates no Ruby object (so no GC can run) and this thread keeps the
    // GVL (so no other Ruby thread can mutate a string). The strings stay
    // referenced by the caller's Ruby arguments.
    let bytes: Vec<&[u8]> = strings.iter().map(|string| unsafe { string.as_slice() }).collect();
    f(&bytes)
}

/// `[[class_name, method_name, start_line, end_line], ...]`. A class name is
/// one frozen Ruby string, shared by the rows of its tests.
fn rows(ruby: &Ruby, discovery: &Discovery) -> Result<RArray, Error> {
    // A Ruby array keeps the class names reachable for the GC while the rows
    // are built.
    let classes = ruby.ary_new_capa(discovery.classes().len());
    for class in discovery.classes() {
        let class = ruby.str_new(class);
        class.freeze();
        classes.push(class)?;
    }
    let rows = ruby.ary_new_capa(discovery.len());
    for test in discovery {
        let class: RString = classes.entry(test.class.cast_signed())?;
        rows.push((class, ruby.str_new(test.name), test.start_line, test.end_line))?;
    }
    Ok(rows)
}

/// Checked against `PaddedCell::VERSION` before the extension is used.
const fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

fn discover(ruby: &Ruby, source: RString) -> Result<RArray, Error> {
    let discovery = with_bytes(&[source], |bytes| padded_cell::discover(bytes[0]));
    rows(ruby, &discovery)
}

/// Reads and parses on scoped threads: none is left running when Ruby forks
/// next.
fn discover_files(ruby: &Ruby, paths: RArray) -> Result<RArray, Error> {
    let found = with_bytes(&strings(paths)?, |paths| {
        let paths: Vec<&Path> =
            paths.iter().map(|path| Path::new(OsStr::from_bytes(path))).collect();
        padded_cell::discover_files(&paths)
    })
    .map_err(|error| file_error(ruby, &error))?;
    let files = ruby.ary_new_capa(found.len());
    for discovery in &found {
        files.push(rows(ruby, discovery)?)?;
    }
    Ok(files)
}

fn plan(
    classes: RArray,
    durations: Vec<f64>,
    seed: u64,
    shard_index: u64,
    shard_count: u64,
) -> Result<Vec<Vec<usize>>, Error> {
    Ok(with_bytes(&strings(classes)?, |classes| {
        padded_cell::plan(classes, &durations, seed, shard_index, shard_count)
    }))
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("PaddedCellNative")?;
    module.define_module_function("version", function!(version, 0))?;
    module.define_module_function("discover", function!(discover, 1))?;
    module.define_module_function("discover_files", function!(discover_files, 1))?;
    module.define_module_function("plan", function!(plan, 5))?;
    module.define_module_function("chart_report", function!(chart::chart_report, 3))?;
    Ok(())
}
