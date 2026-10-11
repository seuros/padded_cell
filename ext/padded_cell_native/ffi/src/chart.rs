use std::path::PathBuf;

use magnus::{Error, RArray, RHash, Ruby, Symbol, TryConvert, Value};
use padded_cell::chart::{
    self, Arm, CRITERIA, Condition, Criterion, FileCoverage, Format, Meta, Method, Options, Scope,
    Span, Stats, Summary, Thresholds, Totals,
};

use crate::file_error;
use padded_cell::FileError;

/// Reads every source, writes the reports, checks the thresholds, and
/// returns what it found:
///
/// ```text
/// files    [[path, name, lines, branches or nil, methods or nil, loaded], ...]
///            branches  [[type, l1, c1, l2, c2, [[type, l1, c1, l2, c2, hits], ...]], ...]
///            methods   [[owner, name, l1, c1, l2, c2, hits], ...]
/// groups   [[name, [file index, ...]], ...]
/// options  {dir:, formats: ["lcov", "json"], nocov_token:, criteria: ["line", "branch"],
///           minimum:, minimum_by_file:, maximum_drop:, last_run: [line, branch, method] (nil: none),
///           minimum_by_group: [[name, [line, branch, method]], ...], write_last_run:,
///           root:, timestamp:, created_at:, commit:, project_name:, generator:}
///
/// => {total: stats, groups: [[name, stats], ...], files: [[name, stats], ...],
///     violations: [[scope, name or nil, criterion, limit, actual], ...]}
///    stats  {line: [covered, missed, omitted, hits, percent, strength], branch: ..., method: ...}
/// ```
pub fn chart_report(
    ruby: &Ruby,
    files: RArray,
    groups: Vec<(String, Vec<usize>)>,
    options: RHash,
) -> Result<RHash, Error> {
    let option = |key: &str| ruby.to_symbol(key);
    let formats = options
        .fetch::<_, Vec<String>>(option("formats"))?
        .iter()
        .map(|name| name.parse::<Format>())
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| Error::new(ruby.exception_arg_error(), error.to_string()))?;
    let measured: Vec<Criterion> = options
        .fetch::<_, Vec<String>>(option("criteria"))?
        .iter()
        .filter_map(|name| CRITERIA.into_iter().find(|criterion| criterion.singular() == name))
        .collect();
    let thresholds = Thresholds {
        minimum: options.fetch(option("minimum"))?,
        minimum_by_file: options.fetch(option("minimum_by_file"))?,
        minimum_by_group: options.fetch(option("minimum_by_group"))?,
        maximum_drop: options.fetch(option("maximum_drop"))?,
        last_run: options.fetch(option("last_run"))?,
    };
    let meta = Meta {
        root: options.fetch(option("root"))?,
        timestamp: options.fetch(option("timestamp"))?,
        created_at: options.fetch(option("created_at"))?,
        commit: options.fetch(option("commit"))?,
        project_name: options.fetch(option("project_name"))?,
        generator: options.fetch(option("generator"))?,
    };
    let dir: PathBuf = options.fetch(option("dir"))?;
    let analysis = Options {
        nocov_token: options.fetch(option("nocov_token"))?,
        methods: measured.contains(&Criterion::Method),
    };
    let files = (0..files.len())
        .map(|index| file(files.entry(index.cast_signed())?))
        .collect::<Result<Vec<_>, Error>>()?;

    let failed = |error: FileError| file_error(ruby, &error);
    let reports = chart::analyze_all(&files, &analysis).map_err(failed)?;
    let totals = Totals::of_files(&reports);
    let groups: Vec<(String, Vec<usize>, Totals)> = groups
        .into_iter()
        .map(|(name, members)| {
            let totals = Totals::of_files(members.iter().filter_map(|&index| reports.get(index)));
            (name, members, totals)
        })
        .collect();
    let named: Vec<(String, Totals)> =
        groups.iter().map(|(name, _, totals)| (name.clone(), *totals)).collect();
    let violations = chart::violations(&thresholds, &measured, &totals, &reports, &named);
    let summary = Summary { files: &reports, measured, totals, groups, violations, meta };
    for format in formats {
        chart::write(&dir, format, &summary).map_err(failed)?;
    }
    if options.fetch(option("write_last_run"))? {
        chart::write_last_run_file(&dir, &summary).map_err(failed)?;
    }
    result(ruby, &summary)
}

fn result(ruby: &Ruby, summary: &Summary<'_>) -> Result<RHash, Error> {
    let result = ruby.hash_new();
    result.aset(ruby.to_symbol("total"), totals(ruby, &summary.totals)?)?;
    let groups = ruby.ary_new_capa(summary.groups.len());
    for (name, _, group) in &summary.groups {
        groups.push((name.as_str(), totals(ruby, group)?))?;
    }
    result.aset(ruby.to_symbol("groups"), groups)?;
    let files = ruby.ary_new_capa(summary.files.len());
    for report in summary.files {
        let stats = criteria(ruby, |criterion| report.stats.with_percent(criterion))?;
        files.push((report.file.name.as_str(), stats))?;
    }
    result.aset(ruby.to_symbol("files"), files)?;
    let violations = ruby.ary_new_capa(summary.violations.len());
    for violation in &summary.violations {
        let (scope, name) = match &violation.scope {
            Scope::Total => ("total", None),
            Scope::File(name) => ("file", Some(name.as_str())),
            Scope::Group(name) => ("group", Some(name.as_str())),
            Scope::Drop => ("drop", None),
        };
        let criterion = violation.criterion.singular();
        violations.push((
            ruby.to_symbol(scope),
            name,
            ruby.to_symbol(criterion),
            violation.limit,
            violation.actual,
        ))?;
    }
    result.aset(ruby.to_symbol("violations"), violations)?;
    Ok(result)
}

fn totals(ruby: &Ruby, totals: &Totals) -> Result<RHash, Error> {
    criteria(ruby, |criterion| {
        let stats = totals.get(criterion);
        (stats, stats.percent())
    })
}

fn criteria(ruby: &Ruby, stats: impl Fn(Criterion) -> (Stats, f64)) -> Result<RHash, Error> {
    let hash = ruby.hash_new();
    for criterion in CRITERIA {
        let (stats, percent) = stats(criterion);
        let row =
            (stats.covered, stats.missed, stats.omitted, stats.hits, percent, stats.strength());
        hash.aset(ruby.to_symbol(criterion.singular()), row)?;
    }
    Ok(hash)
}

fn file(row: RArray) -> Result<FileCoverage, Error> {
    Ok(FileCoverage {
        path: row.entry(0)?,
        name: row.entry(1)?,
        lines: row.entry::<RArray>(2)?.to_vec()?,
        branches: row.entry::<Option<RArray>>(3)?.map(conditions).transpose()?,
        methods: row.entry::<Option<RArray>>(4)?.map(methods).transpose()?,
        loaded: row.entry(5)?,
    })
}

fn conditions(rows: RArray) -> Result<Vec<Condition>, Error> {
    rows.into_iter()
        .map(|row| {
            let row = RArray::try_convert(row)?;
            let arms = RArray::try_convert(row.entry(5)?)?
                .into_iter()
                .map(|arm| {
                    let arm = RArray::try_convert(arm)?;
                    Ok(Arm { kind: name(arm.entry(0)?)?, span: span(arm, 1)?, hits: arm.entry(5)? })
                })
                .collect::<Result<_, Error>>()?;
            Ok(Condition { kind: name(row.entry(0)?)?, span: span(row, 1)?, arms })
        })
        .collect()
}

fn methods(rows: RArray) -> Result<Vec<Method>, Error> {
    rows.into_iter()
        .map(|row| {
            let row = RArray::try_convert(row)?;
            Ok(Method {
                owner: row.entry(0)?,
                name: name(row.entry(1)?)?,
                span: span(row, 2)?,
                hits: row.entry(6)?,
            })
        })
        .collect()
}

/// Four integers from `at`: first line, first column, last line, last column.
fn span(row: RArray, at: isize) -> Result<Span, Error> {
    Ok(Span {
        start_line: row.entry(at)?,
        start_column: row.entry(at.strict_add(1))?,
        end_line: row.entry(at.strict_add(2))?,
        end_column: row.entry(at.strict_add(3))?,
    })
}

/// A branch type or method name: a Symbol from Ruby's Coverage, a String
/// once through JSON.
fn name(value: Value) -> Result<String, Error> {
    match Symbol::from_value(value) {
        Some(symbol) => Ok(symbol.name()?.into_owned()),
        None => String::try_convert(value),
    }
}
