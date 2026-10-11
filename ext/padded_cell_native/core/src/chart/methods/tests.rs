use super::*;

#[test]
fn defs_with_their_innermost_owner_and_span() {
    let source = Source::new(
        concat!(
            "def top = 1\nmodule A\n  class B::C\n  é = 1; def x(y)\n    y\n  end\n",
            "    def self.z = 2\n  end\nend\n",
        )
        .as_bytes()
        .to_vec(),
    );
    let found: Vec<(String, String, Span)> = static_methods(&source)
        .unwrap()
        .into_iter()
        .map(|method| (method.owner, method.name, method.span))
        .collect();
    let span = |start_line, start_column, end_line, end_column| Span {
        start_line,
        start_column,
        end_line,
        end_column,
    };
    assert_eq!(
        found,
        [
            ("Object".to_owned(), "top".to_owned(), span(1, 0, 1, 11)),
            // Columns count bytes, as Ruby's do: é is two.
            ("B::C".to_owned(), "x".to_owned(), span(4, 10, 6, 5)),
            ("B::C".to_owned(), "z".to_owned(), span(7, 4, 7, 18)),
        ]
    );
}

#[test]
fn sources_that_do_not_parse_have_no_methods() {
    assert_eq!(static_methods(&Source::new(b"def broken(\n".to_vec())), None);
}
