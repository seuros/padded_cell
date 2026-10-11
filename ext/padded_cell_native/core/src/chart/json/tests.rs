use super::*;

fn render(pretty: bool, write: impl FnOnce(&mut Json<'_, Vec<u8>>) -> io::Result<()>) -> String {
    let mut out = Vec::new();
    let mut json = if pretty { Json::pretty(&mut out) } else { Json::compact(&mut out) };
    write(&mut json).unwrap();
    String::from_utf8(out).unwrap()
}

/// Ruby's output for `{a: [], b: {}, c: [1, {d: nil}]}`.
#[test]
fn layouts_of_pretty_generate_and_generate() {
    let document = |json: &mut Json<'_, Vec<u8>>| {
        json.object(|json| {
            json.key("a")?.array(|_| Ok(()))?;
            json.key("b")?.object(|_| Ok(()))?;
            json.key("c")?.array(|json| {
                json.item()?.uint(1)?;
                json.item()?.object(|json| json.key("d")?.null())
            })
        })
    };
    assert_eq!(
        render(true, document),
        "{\n  \"a\": [],\n  \"b\": {},\n  \"c\": [\n    1,\n    {\n      \"d\": null\n    }\n  ]\n}"
    );
    assert_eq!(render(false, document), r#"{"a":[],"b":{},"c":[1,{"d":null}]}"#);
}

/// Ruby's `JSON.generate(["\x1f\x01\b\f\n\r\t\"\\/é ", 100.0, 66.66666666666667, 0.1 + 0.2])`.
#[test]
fn strings_and_floats_as_ruby_writes_them() {
    let rendered = render(false, |json| {
        json.array(|json| {
            json.item()?.str("\u{1f}\u{1}\u{8}\u{c}\n\r\t\"\\/é ")?;
            json.item()?.float(100.0)?;
            json.item()?.float(200.0 / 3.0)?;
            json.item()?.float(0.1 + 0.2)?;
            json.item()?.bool(false)
        })
    });
    assert_eq!(
        rendered,
        r#"["\u001f\u0001\b\f\n\r\t\"\\/é ",100.0,66.66666666666667,0.30000000000000004,false]"#
    );
}
