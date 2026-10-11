use std::io::{self, Write};

use super::json::Json;
use super::stats::{Criterion, Stats, Totals};
use super::thresholds::{CRITERIA, Scope, Violation};
use super::{Branch, FileReport, Line, chomp, floor2};

#[cfg(test)]
mod tests;

const SCHEMA: &str = concat!(
    "https://raw.githubusercontent.com/simplecov-ruby/simplecov/main/",
    "schemas/coverage-v1.3.schema.json",
);
const COMMAND: &str = "padded_cell";

/// About the run.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Meta {
    /// The project root, absolute.
    pub root: String,
    /// ISO 8601, with milliseconds.
    pub timestamp: String,
    /// The same moment, in seconds since the epoch.
    pub created_at: f64,
    /// The root's git HEAD.
    pub commit: Option<String>,
    pub project_name: String,
    /// What wrote the report: `padded_cell 0.1.0`.
    pub generator: String,
}

/// Everything a report says about a run.
#[derive(Debug)]
pub struct Summary<'a> {
    pub files: &'a [FileReport<'a>],
    pub measured: Vec<Criterion>,
    pub totals: Totals,
    /// Name, indices into `files`, and their totals.
    pub groups: Vec<(String, Vec<usize>, Totals)>,
    pub violations: Vec<Violation>,
    pub meta: Meta,
}

impl Summary<'_> {
    /// `criterion` was measured.
    #[must_use]
    pub fn measures(&self, criterion: Criterion) -> bool {
        self.measured.contains(&criterion)
    }
}

/// `coverage.json`.
///
/// # Errors
///
/// What writing to `out` returns.
pub fn write_coverage_json(summary: &Summary<'_>, out: &mut impl Write) -> io::Result<()> {
    Json::pretty(out).object(|json| {
        json.key("$schema")?.str(SCHEMA)?;
        json.key("meta")?.object(|json| meta(json, summary))?;
        json.key("total")?.object(|json| statistics(json, summary, &summary.totals))?;
        json.key("coverage")?.object(|json| {
            summary.files.iter().try_for_each(|file| {
                json.key(&file.file.name)?.object(|json| source_file(json, summary, file))
            })
        })?;
        json.key("groups")?.object(|json| {
            summary.groups.iter().try_for_each(|(name, members, totals)| {
                json.key(name)?.object(|json| {
                    statistics(json, summary, totals)?;
                    json.key("files")?.array(|json| {
                        let names = members.iter().filter_map(|&index| summary.files.get(index));
                        names.into_iter().try_for_each(|file| json.item()?.str(&file.file.name))
                    })
                })
            })
        })?;
        json.key("errors")?.object(|json| errors(json, &summary.violations))
    })
}

/// `.resultset.json`: Ruby's Coverage result, keyed by absolute path, under
/// the command name.
///
/// # Errors
///
/// What writing to `out` returns.
pub fn write_resultset(summary: &Summary<'_>, out: &mut impl Write) -> io::Result<()> {
    Json::compact(out).object(|json| {
        json.key(COMMAND)?.object(|json| {
            json.key("coverage")?.object(|json| {
                let methods = summary.measures(Criterion::Method);
                summary.files.iter().try_for_each(|file| {
                    let path = file.file.path.to_string_lossy();
                    json.key(&path)?.object(|json| resultset_file(json, file, methods))
                })
            })?;
            json.key("timestamp")?.float(summary.meta.created_at)
        })
    })?;
    out.write_all(b"\n")
}

/// `.last_run.json`: the run's percents, floored, which the next run's
/// `maximum_drop` compares with.
///
/// # Errors
///
/// What writing to `out` returns.
pub fn write_last_run(summary: &Summary<'_>, out: &mut impl Write) -> io::Result<()> {
    Json::pretty(out).object(|json| {
        json.key("result")?.object(|json| {
            summary.measured.iter().try_for_each(|&criterion| {
                json.key(criterion.singular())?
                    .float(floor2(summary.totals.get(criterion).percent()))
            })
        })
    })?;
    out.write_all(b"\n")
}

fn meta<W: Write>(json: &mut Json<'_, W>, summary: &Summary<'_>) -> io::Result<()> {
    let meta = &summary.meta;
    json.key("schema_version")?.str("1.3")?;
    json.key("simplecov_version")?.str(&meta.generator)?;
    json.key("command_name")?.str(COMMAND)?;
    json.key("command_names")?.array(|json| json.item()?.str(COMMAND))?;
    json.key("project_name")?.str(&meta.project_name)?;
    json.key("timestamp")?.str(&meta.timestamp)?;
    json.key("root")?.str(&meta.root)?;
    match &meta.commit {
        Some(commit) => json.key("commit")?.str(commit)?,
        None => json.key("commit")?.null()?,
    }
    json.key("primary_coverage")?.str("line")?;
    for criterion in CRITERIA {
        let key = format!("{}_coverage", criterion.singular());
        json.key(&key)?.bool(summary.measures(criterion))?;
    }
    Ok(())
}

fn statistics<W: Write>(
    json: &mut Json<'_, W>,
    summary: &Summary<'_>,
    totals: &Totals,
) -> io::Result<()> {
    summary.measured.iter().try_for_each(|&criterion| {
        let stats = totals.get(criterion);
        json.key(criterion.plural())?
            .object(|json| statistic(json, criterion, &stats, stats.percent()))
    })
}

fn statistic<W: Write>(
    json: &mut Json<'_, W>,
    criterion: Criterion,
    stats: &Stats,
    percent: f64,
) -> io::Result<()> {
    json.key("covered")?.uint(stats.covered)?;
    json.key("missed")?.uint(stats.missed)?;
    if criterion == Criterion::Line {
        json.key("omitted")?.uint(stats.omitted)?;
    }
    json.key("total")?.uint(stats.total())?;
    json.key("percent")?.float(percent)?;
    json.key("strength")?.float(stats.strength())
}

fn source_file<W: Write>(
    json: &mut Json<'_, W>,
    summary: &Summary<'_>,
    file: &FileReport<'_>,
) -> io::Result<()> {
    json.key("source")?.array(|json| {
        file.lines()
            .try_for_each(|line| json.item()?.str(&String::from_utf8_lossy(chomp(line.text))))
    })?;
    let stats = &file.stats;
    json.key("lines")?.array(|json| file.lines().try_for_each(|line| hits(json.item()?, &line)))?;
    json.key("lines_covered_percent")?.float(stats.percent(Criterion::Line))?;
    json.key("covered_lines")?.uint(stats.counts.line.covered)?;
    json.key("missed_lines")?.uint(stats.counts.line.missed)?;
    json.key("omitted_lines")?.uint(stats.counts.line.omitted)?;
    json.key("total_lines")?.uint(stats.counts.line.total())?;
    if summary.measures(Criterion::Branch) {
        json.key("branches")?
            .array(|json| file.branches().try_for_each(|b| branch(json.item()?, &b)))?;
        counts(json, "branches", stats.percent(Criterion::Branch), &stats.counts.branch)?;
    }
    if summary.measures(Criterion::Method) {
        json.key("methods")?.array(|json| {
            file.methods().try_for_each(|method| {
                json.item()?.object(|json| {
                    let name = format!("{}#{}", method.method.owner, method.method.name);
                    json.key("name")?.str(&name)?;
                    json.key("start_line")?.uint(method.method.span.start_line.into())?;
                    json.key("end_line")?.uint(method.method.span.end_line.into())?;
                    let coverage = json.key("coverage")?;
                    if method.skipped {
                        coverage.str("ignored")
                    } else {
                        coverage.uint(method.method.hits)
                    }
                })
            })
        })?;
        counts(json, "methods", stats.percent(Criterion::Method), &stats.counts.method)?;
    }
    Ok(())
}

fn counts<W: Write>(
    json: &mut Json<'_, W>,
    name: &str,
    percent: f64,
    stats: &Stats,
) -> io::Result<()> {
    json.key(&format!("{name}_covered_percent"))?.float(percent)?;
    json.key(&format!("covered_{name}"))?.uint(stats.covered)?;
    json.key(&format!("missed_{name}"))?.uint(stats.missed)?;
    json.key(&format!("total_{name}"))?.uint(stats.total())
}

/// Hits, `null` for no code, `"ignored"` for a skipped line.
fn hits<W: Write>(json: &mut Json<'_, W>, line: &Line<'_>) -> io::Result<()> {
    match line.hits {
        _ if line.skipped => json.str("ignored"),
        Some(hits) => json.uint(hits),
        None => json.null(),
    }
}

fn branch<W: Write>(json: &mut Json<'_, W>, branch: &Branch<'_>) -> io::Result<()> {
    json.object(|json| {
        json.key("type")?.str(branch.kind)?;
        json.key("start_line")?.uint(branch.start_line.into())?;
        json.key("end_line")?.uint(branch.end_line.into())?;
        let coverage = json.key("coverage")?;
        if branch.skipped {
            coverage.str("ignored")?;
        } else {
            coverage.uint(branch.hits)?;
        }
        json.key("inline")?.bool(branch.inline)?;
        json.key("report_line")?.uint(branch.report_line().into())
    })
}

/// The violations, by kind.
fn errors<W: Write>(json: &mut Json<'_, W>, violations: &[Violation]) -> io::Result<()> {
    let total: Vec<&Violation> = violations.iter().filter(|v| v.scope == Scope::Total).collect();
    section(json, "minimum_coverage", "expected", &total)?;
    named(json, "minimum_coverage_by_file", violations, |v| match &v.scope {
        Scope::File(name) => Some(name),
        _ => None,
    })?;
    named(json, "minimum_coverage_by_group", violations, |v| match &v.scope {
        Scope::Group(name) => Some(name),
        _ => None,
    })?;
    let drops: Vec<&Violation> = violations.iter().filter(|v| v.scope == Scope::Drop).collect();
    section(json, "maximum_coverage_drop", "maximum", &drops)
}

fn section<W: Write>(
    json: &mut Json<'_, W>,
    key: &str,
    limit: &str,
    found: &[&Violation],
) -> io::Result<()> {
    if found.is_empty() {
        return Ok(());
    }
    json.key(key)?.object(|json| found.iter().try_for_each(|v| violation(json, limit, v)))
}

/// Violations by file or group name; a name's violations come together.
fn named<W: Write>(
    json: &mut Json<'_, W>,
    key: &str,
    violations: &[Violation],
    name: impl Fn(&Violation) -> Option<&String>,
) -> io::Result<()> {
    let mut names: Vec<&String> = violations.iter().filter_map(&name).collect();
    names.dedup();
    if names.is_empty() {
        return Ok(());
    }
    json.key(key)?.object(|json| {
        names.iter().try_for_each(|&scope| {
            let found: Vec<&Violation> =
                violations.iter().filter(|v| name(v) == Some(scope)).collect();
            json.key(scope)?
                .object(|json| found.iter().try_for_each(|v| violation(json, "expected", v)))
        })
    })
}

fn violation<W: Write>(
    json: &mut Json<'_, W>,
    limit: &str,
    violation: &Violation,
) -> io::Result<()> {
    json.key(violation.criterion.plural())?.object(|json| {
        json.key(limit)?.float(violation.limit)?;
        json.key("actual")?.float(violation.actual)
    })
}

fn resultset_file<W: Write>(
    json: &mut Json<'_, W>,
    file: &FileReport<'_>,
    methods: bool,
) -> io::Result<()> {
    json.key("lines")?.array(|json| {
        file.raw_lines().iter().try_for_each(|hits| match hits {
            Some(hits) => json.item()?.uint(*hits),
            None => json.item()?.null(),
        })
    })?;
    if let Some(conditions) = &file.file.branches {
        // Ruby numbers conditions and arms in the order it compiled them.
        let mut id = 0_u64;
        json.key("branches")?.object(|json| {
            conditions.iter().try_for_each(|condition| {
                json.key(&ruby_tuple(&condition.kind, &mut id, &condition.span))?.object(|json| {
                    condition.arms.iter().try_for_each(|arm| {
                        json.key(&ruby_tuple(&arm.kind, &mut id, &arm.span))?.uint(arm.hits)
                    })
                })
            })
        })?;
    }
    if methods {
        json.key("methods")?.object(|json| {
            file.methods().try_for_each(|method| {
                let span = &method.method.span;
                let key = format!(
                    "[{}, {}, {}, {}, {}, {}]",
                    method.method.owner,
                    ruby_symbol(&method.method.name),
                    span.start_line,
                    span.start_column,
                    span.end_line,
                    span.end_column
                );
                json.key(&key)?.uint(method.method.hits)
            })
        })?;
    }
    Ok(())
}

/// `[:if, 0, 2, 4, 6, 7]`, as Ruby's `Array#to_s` writes a branch key.
fn ruby_tuple(kind: &str, id: &mut u64, span: &super::Span) -> String {
    let tuple = format!(
        "[{}, {id}, {}, {}, {}, {}]",
        ruby_symbol(kind),
        span.start_line,
        span.start_column,
        span.end_line,
        span.end_column
    );
    *id = id.strict_add(1);
    tuple
}

/// `:if`, or `:"&."` for a symbol that needs quoting.
fn ruby_symbol(name: &str) -> String {
    let plain = name
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b"_?!=[]+-*/%<>~^&|".contains(&byte))
        && !name.is_empty()
        && name != "&.";
    if plain { format!(":{name}") } else { format!(":{name:?}") }
}
