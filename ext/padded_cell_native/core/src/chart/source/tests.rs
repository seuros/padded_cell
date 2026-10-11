use super::*;

fn source(text: &str) -> Source {
    Source::new(text.as_bytes().to_vec())
}

#[test]
fn lines_split_as_ruby_readlines() {
    const CASES: &[(&str, &[&str])] = &[
        ("", &[]),
        ("a", &["a"]),
        ("a\nb", &["a\n", "b"]),
        ("a\nb\n", &["a\n", "b\n"]),
        ("\n\n", &["\n", "\n"]),
        ("a\r\nb", &["a\r\n", "b"]),
    ];
    for (text, expected) in CASES {
        let source = source(text);
        let lines: Vec<&[u8]> = source.lines().collect();
        let expected: Vec<&[u8]> = expected.iter().map(|line| line.as_bytes()).collect();
        assert_eq!(lines, expected, "text: {text:?}");
        assert_eq!(source.len(), expected.len(), "text: {text:?}");
    }
}

#[test]
fn blank_and_comment_lines() {
    const CASES: &[(&str, bool)] = &[
        ("", true),
        ("\n", true),
        ("  \t\r\n", true),
        ("# comment\n", true),
        ("   # indented\n", true),
        ("\x0b\x0c#\n", true),
        ("code\n", false),
        ("x = 1 # comment\n", false),
        ("  end", false),
    ];
    for (line, expected) in CASES {
        assert_eq!(blank_or_comment(line.as_bytes()), *expected, "line: {line:?}");
    }
}

#[test]
fn nocov_blocks_run_from_marker_to_marker() {
    let text = "a\n# :nocov:\nb\n  #   :nocov: done\nc\nd # :nocov:\n#:nocov:\ne\n";
    assert_eq!(source(text).nocov("nocov"), [2..=4, 7..=8]);
    assert_eq!(source(text).nocov("skip"), []);
    assert_eq!(source("a\n# :skip:\nb\n").nocov("skip"), [RangeInclusive::new(2, 3)]);
    // A marker needs both colons: `# :nocov` is a comment.
    assert_eq!(source("# :nocov\n# nocov:\n").nocov("nocov"), []);
}

#[test]
fn unloaded_files_keep_only_their_code() {
    let source = source("# frozen\n\nclass A\n  # :nocov:\n  def b; end\n  # :nocov:\nend\n");
    let stub = [Some(0), Some(0), Some(0), Some(0), Some(0), Some(0), Some(0), Some(0)];
    let skipped = source.nocov("nocov");
    assert_eq!(
        source.relevant(&stub, &skipped),
        [None, None, Some(0), None, None, None, Some(0), None],
        "comments, blank lines, blocks, and lines past the source are not code"
    );
}
