//! Static Minitest discovery.
//!
//! A test class is a class whose superclass constant ends in `Test` or
//! `TestCase` (`Minitest::Test`, `ActiveSupport::TestCase`, an app's own
//! `BaseTest`...). Its tests are `def test_*` methods and Rails'
//! `test "name"` declarations. Nothing is evaluated.

use std::iter::FusedIterator;
use std::path::Path;
use std::slice;

use ruby_prism::{
    CallNode, ClassNode, DefNode, Location, ModuleNode, Node, SingletonClassNode, Visit,
};

use crate::FileError;
use crate::parallel::fill;

#[cfg(test)]
mod tests;

/// The tests of one source. Each class name is stored once, however many
/// tests the class has.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Discovery {
    classes: Vec<String>,
    tests: Vec<Entry>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Entry {
    class: usize,
    name: String,
    start_line: usize,
    end_line: usize,
}

/// A discovered test, borrowed from its [`Discovery`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TestDef<'a> {
    /// Full constant name of the class: `Admin::UsersControllerTest`.
    pub class_name: &'a str,
    /// Index of the class in [`Discovery::classes`].
    pub class: usize,
    /// Method name: `test_index_lists_users` for `test "index lists users"`.
    pub name: &'a str,
    /// 1-based line where the definition starts.
    pub start_line: usize,
    /// 1-based line where it ends.
    pub end_line: usize,
}

impl TestDef<'_> {
    /// `Class#method`, the id Minitest filters match.
    #[must_use]
    pub fn id(&self) -> String {
        format!("{}#{}", self.class_name, self.name)
    }
}

impl Discovery {
    /// Names of the test classes that have tests, in order of appearance.
    #[must_use]
    pub fn classes(&self) -> &[String] {
        &self.classes
    }

    /// Number of tests.
    #[must_use]
    pub const fn len(&self) -> usize {
        self.tests.len()
    }

    /// Whether no test was found.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.tests.is_empty()
    }

    /// The tests, in source order.
    #[must_use]
    pub fn iter(&self) -> Iter<'_> {
        Iter { classes: &self.classes, tests: self.tests.iter() }
    }
}

impl<'a> IntoIterator for &'a Discovery {
    type Item = TestDef<'a>;
    type IntoIter = Iter<'a>;

    fn into_iter(self) -> Iter<'a> {
        self.iter()
    }
}

/// Iterator over the tests of a [`Discovery`].
#[derive(Debug, Clone)]
pub struct Iter<'a> {
    classes: &'a [String],
    tests: slice::Iter<'a, Entry>,
}

impl<'a> Iterator for Iter<'a> {
    type Item = TestDef<'a>;

    fn next(&mut self) -> Option<TestDef<'a>> {
        let entry = self.tests.next()?;
        Some(TestDef {
            class_name: &self.classes[entry.class],
            class: entry.class,
            name: &entry.name,
            start_line: entry.start_line,
            end_line: entry.end_line,
        })
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.tests.size_hint()
    }
}

impl ExactSizeIterator for Iter<'_> {}

impl FusedIterator for Iter<'_> {}

/// The tests defined in `source`, in source order. Syntax errors do not
/// stop discovery: what Prism recovers is reported.
#[must_use]
pub fn discover(source: &[u8]) -> Discovery {
    let result = ruby_prism::parse(source);
    let mut visitor = Visitor::new(source);
    visitor.visit(&result.node());
    visitor.discovery
}

/// [`discover`] for every source, spread over the available cores. Results
/// keep the order of `sources`.
#[must_use]
pub fn discover_many<S: AsRef<[u8]> + Sync>(sources: &[S]) -> Vec<Discovery> {
    let mut found = vec![Discovery::default(); sources.len()];
    let Ok(()) = fill(sources, &mut found, |source| {
        Ok::<_, std::convert::Infallible>(discover(source.as_ref()))
    });
    found
}

/// Reads and discovers one file, parsed from the buffer it was read into.
///
/// # Errors
///
/// [`FileError`] when the file cannot be read.
pub fn discover_file(path: impl AsRef<Path>) -> Result<Discovery, FileError> {
    let path = path.as_ref();
    let source = FileError::read(path)?;
    Ok(discover(&source))
}

/// [`discover_file`] for every path, spread over the available cores.
/// Results keep the order of `paths`.
///
/// # Errors
///
/// The [`FileError`] of the first unreadable file, in input order.
pub fn discover_files<P: AsRef<Path> + Sync>(paths: &[P]) -> Result<Vec<Discovery>, FileError> {
    let mut found = vec![Discovery::default(); paths.len()];
    fill(paths, &mut found, discover_file)?;
    Ok(found)
}

/// Walks the tree. Names are borrowed from the parse result until a test
/// class needs its full name.
struct Visitor<'pr> {
    lines: Lines<'pr>,
    /// Constant names of the enclosing namespaces, outermost first.
    scope: Vec<&'pr str>,
    /// Where the current namespace starts in `scope`: an absolute path
    /// (`class ::A`) starts a new one.
    scope_start: usize,
    /// Set inside a namespace whose name is not a constant (`class foo::A`):
    /// nothing below it has a known name.
    dynamic: bool,
    test_class: TestClass,
    discovery: Discovery,
}

/// Byte offset to 1-based line, without an index: a cursor counts the
/// newlines between the offsets it is asked for. A pre-order walk asks for
/// start offsets in increasing order, and an end is counted from its start,
/// so the source is read about once.
struct Lines<'s> {
    source: &'s [u8],
    offset: usize,
    line: usize,
}

impl Lines<'_> {
    fn at(&mut self, offset: usize) -> usize {
        let newlines =
            |bytes: &[u8]| bytes.iter().fold(0, |n, &byte| n + usize::from(byte == b'\n'));
        // Going back never passes line 1: overflow either way is a bug.
        self.line = if offset >= self.offset {
            self.line.strict_add(newlines(&self.source[self.offset..offset]))
        } else {
            self.line.strict_sub(newlines(&self.source[offset..self.offset]))
        };
        self.offset = offset;
        self.line
    }
}

/// Where the visitor stands: outside a test class, or inside one whose name
/// is joined and stored when its first test is found (abstract base classes
/// never are).
#[derive(Debug, Clone, Copy)]
enum TestClass {
    Outside,
    Pending,
    Stored(usize),
}

impl<'pr> Visitor<'pr> {
    const fn new(source: &'pr [u8]) -> Self {
        Self {
            lines: Lines { source, offset: 0, line: 1 },
            scope: Vec::new(),
            scope_start: 0,
            dynamic: false,
            test_class: TestClass::Outside,
            discovery: Discovery { classes: Vec::new(), tests: Vec::new() },
        }
    }

    fn within(&mut self, path: &Node<'pr>, test: bool, visit: impl FnOnce(&mut Self)) {
        let (depth, scope_start, dynamic, test_class) =
            (self.scope.len(), self.scope_start, self.dynamic, self.test_class);
        let constant = self.push_constant(path).is_some();
        self.dynamic |= !constant;
        self.test_class =
            if test && !self.dynamic { TestClass::Pending } else { TestClass::Outside };
        visit(self);
        self.scope.truncate(depth);
        (self.scope_start, self.dynamic, self.test_class) = (scope_start, dynamic, test_class);
    }

    /// Pushes the names of a constant path onto the scope, or returns `None`
    /// when a part of it is not a constant.
    fn push_constant(&mut self, node: &Node<'pr>) -> Option<()> {
        let (parent, name) = constant(node)?;
        match parent {
            Parent::None => {}
            Parent::Root => self.scope_start = self.scope.len(),
            Parent::Path(parent) => self.push_constant(&parent)?,
        }
        self.scope.push(name);
        Some(())
    }

    /// Stores the current namespace as a class name, joined once.
    fn add_class(&mut self) -> usize {
        let names = &self.scope[self.scope_start..];
        let length =
            names.iter().map(|name| name.len()).sum::<usize>() + 2 * names.len().saturating_sub(1);
        let mut class = String::with_capacity(length);
        for (index, name) in names.iter().enumerate() {
            if index > 0 {
                class.push_str("::");
            }
            class.push_str(name);
        }
        self.discovery.classes.push(class);
        self.discovery.classes.len() - 1
    }

    const fn in_test_class(&self) -> bool {
        !matches!(self.test_class, TestClass::Outside)
    }

    fn record(&mut self, name: String, location: &Location<'_>) {
        let class = match self.test_class {
            TestClass::Outside => return,
            TestClass::Stored(class) => class,
            TestClass::Pending => {
                let class = self.add_class();
                self.test_class = TestClass::Stored(class);
                class
            }
        };
        let entry = Entry {
            class,
            name,
            start_line: self.lines.at(location.start_offset()),
            end_line: self.lines.at(location.end_offset()),
        };
        self.discovery.tests.push(entry);
    }
}

impl<'pr> Visit<'pr> for Visitor<'pr> {
    fn visit_module_node(&mut self, node: &ModuleNode<'pr>) {
        self.within(&node.constant_path(), false, |visitor| {
            ruby_prism::visit_module_node(visitor, node);
        });
    }

    fn visit_class_node(&mut self, node: &ClassNode<'pr>) {
        let test = node.superclass().is_some_and(|superclass| test_superclass(&superclass));
        self.within(&node.constant_path(), test, |visitor| {
            ruby_prism::visit_class_node(visitor, node);
        });
    }

    /// `class << self` keeps the namespace, but its methods are not tests.
    fn visit_singleton_class_node(&mut self, node: &SingletonClassNode<'pr>) {
        let saved = std::mem::replace(&mut self.test_class, TestClass::Outside);
        ruby_prism::visit_singleton_class_node(self, node);
        self.test_class = saved;
    }

    /// A method body defines nothing on the class: not descended into.
    fn visit_def_node(&mut self, node: &DefNode<'pr>) {
        let name = node.name().as_slice();
        if self.in_test_class()
            && node.receiver().is_none()
            && name.starts_with(b"test_")
            && let Some(name) = utf8(name)
        {
            self.record(name.to_owned(), &node.location());
        }
    }

    fn visit_call_node(&mut self, node: &CallNode<'pr>) {
        if self.in_test_class()
            && node.receiver().is_none()
            && node.name().as_slice() == b"test"
            && let Some(name) = declared_name(node)
        {
            self.record(name, &node.location());
        }
        ruby_prism::visit_call_node(self, node);
    }
}

/// Whether a superclass is a constant path ending in `Test` or `TestCase`.
fn test_superclass(node: &Node<'_>) -> bool {
    constant_tail(node).is_some_and(|name| name.ends_with("Test") || name.ends_with("TestCase"))
}

/// The last name of a constant path, when every part of it is a constant.
fn constant_tail<'pr>(node: &Node<'pr>) -> Option<&'pr str> {
    let (parent, name) = constant(node)?;
    if let Parent::Path(parent) = parent {
        constant_tail(&parent)?;
    }
    Some(name)
}

/// What a constant's name is relative to.
enum Parent<'pr> {
    /// `A`: the enclosing namespace.
    None,
    /// `::A`: the top level.
    Root,
    /// `B::A`: another constant path (or an expression, for `foo::A`).
    Path(Node<'pr>),
}

/// A constant node's own name, borrowed from the parse result, and what it
/// is relative to. `None` for any other node.
fn constant<'pr>(node: &Node<'pr>) -> Option<(Parent<'pr>, &'pr str)> {
    if let Some(read) = node.as_constant_read_node() {
        return Some((Parent::None, utf8(read.name().as_slice())?));
    }
    let path = node.as_constant_path_node()?;
    let parent = path.parent().map_or(Parent::Root, Parent::Path);
    Some((parent, utf8(path.name()?.as_slice())?))
}

/// `test_<name>` for `test "name"` with one plain string argument, the way
/// `ActiveSupport::Testing::Declarative` names it:
/// `"test_#{name.gsub(/\s+/, '_')}"`, Ruby's `\s` being space, `\t`, `\n`,
/// `\v`, `\f` and `\r`.
fn declared_name(node: &CallNode<'_>) -> Option<String> {
    let arguments = node.arguments()?.arguments();
    let mut arguments = arguments.iter();
    let first = arguments.next()?;
    if arguments.next().is_some() {
        return None;
    }
    let string = first.as_string_node()?;
    let name = utf8(string.unescaped())?;
    let mut declared = String::with_capacity("test_".len() + name.len());
    declared.push_str("test_");
    let mut in_whitespace = false;
    for c in name.chars() {
        let whitespace = matches!(c, ' ' | '\t' | '\n' | '\x0b' | '\x0c' | '\r');
        if !whitespace {
            declared.push(c);
        } else if !in_whitespace {
            declared.push('_');
        }
        in_whitespace = whitespace;
    }
    Some(declared)
}

fn utf8(bytes: &[u8]) -> Option<&str> {
    std::str::from_utf8(bytes).ok()
}
