use super::*;

fn skipped(text: &str) -> Skipped {
    Skipped::of(&Source::new(text.as_bytes().to_vec()), "nocov")
}

/// Where the `#` is, disable, and the criteria named.
type Found = Option<(usize, bool, [bool; 3])>;

#[test]
fn directives_found_in_comments() {
    const CASES: &[(&str, Found)] = &[
        ("# simplecov:disable", Some((0, true, [true; 3]))),
        ("#simplecov : enable", Some((0, false, [true; 3]))),
        ("# simplecov:disable branch", Some((0, true, [false, true, false]))),
        ("# simplecov:disable line , method because", Some((0, true, [true, false, true]))),
        // The longest list ending at a word boundary.
        ("# simplecov:disable line, branchy", Some((0, true, [true, false, false]))),
        ("# simplecov:disable lines", Some((0, true, [true; 3]))),
        ("# note # simplecov:disable", Some((7, true, [true; 3]))),
        ("# simplecov:disabled", None),
        ("# simplecov disable", None),
        ("# rubocop:disable Style", None),
    ];
    for (text, expected) in CASES {
        let found = Directive::find(text.as_bytes())
            .map(|(at, directive)| (at, directive.disable, directive.criteria));
        assert_eq!(found, *expected, "comment: {text:?}");
    }
}

#[test]
fn blocks_inline_directives_and_nocov() {
    let text = "\
a
# simplecov:disable branch
b
# simplecov:enable branch
c # simplecov:disable
# :nocov:
d
# :nocov:
# simplecov:disable method
e
";
    let skipped = skipped(text);
    assert_eq!(skipped.line, [6..=8, 5..=5]);
    assert_eq!(skipped.branch, [6..=8, 2..=4, 5..=5]);
    assert_eq!(skipped.method, [6..=8, 5..=5, 9..=10], "an open block runs to the end");
}

#[test]
fn only_real_comments_count() {
    let text = "x = \"# simplecov:disable\"\ny = <<~TEXT\n  # simplecov:disable\nTEXT\n";
    assert_eq!(skipped(text), Skipped::default());
}
