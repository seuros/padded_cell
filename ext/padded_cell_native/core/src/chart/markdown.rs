use std::io::{self, Write};
use std::path::Path;

use super::stats::{Criterion, Stats};
use super::{Branch, FileReport, Line, MethodReport, Summary, chomp, floor2};

#[cfg(test)]
mod tests;

/// GitHub job summaries take up to 1 MiB: files past it are only counted.
const BUDGET: usize = 1_000_000;
/// Lines of missed code shown per file.
const EXCERPT: usize = 40;

/// Writes `summary` as Markdown.
///
/// # Errors
///
/// What writing to `out` returns.
pub fn write_markdown(summary: &Summary<'_>, out: &mut impl Write) -> io::Result<()> {
    let mut head = Vec::new();
    header(&mut head, summary)?;
    out.write_all(&head)?;
    let mut files: Vec<&FileReport<'_>> =
        summary.files.iter().filter(|file| missed(file) > 0).collect();
    if files.is_empty() {
        return out.write_all(b"Everything ran.\n");
    }
    files.sort_by(|a, b| missed(b).cmp(&missed(a)).then_with(|| a.file.name.cmp(&b.file.name)));
    out.write_all(b"## Missed, most first\n")?;
    let mut written = head.len();
    for (index, file) in files.iter().enumerate() {
        let mut section = Vec::new();
        file_section(&mut section, summary, file)?;
        written = written.strict_add(section.len());
        if written > BUDGET {
            let rest = files.len().strict_sub(index);
            return writeln!(out, "\n{rest} more files have missed code: see `lcov.info`.");
        }
        out.write_all(&section)?;
    }
    Ok(())
}

fn header(out: &mut Vec<u8>, summary: &Summary<'_>) -> io::Result<()> {
    let meta = &summary.meta;
    writeln!(out, "# Coverage: {}\n", meta.project_name)?;
    totals(out, summary, |criterion| {
        let stats = summary.totals.get(criterion);
        (stats, stats.percent())
    })?;
    write!(out, "\nGenerated {} by {}", meta.timestamp, meta.generator)?;
    if let Some(commit) = &meta.commit {
        write!(out, ", at `{}`", commit.get(..12).unwrap_or(commit))?;
    }
    out.write_all(b".\n\n")?;
    if summary.groups.is_empty() {
        return Ok(());
    }
    out.write_all(b"| Group |")?;
    for &criterion in &summary.measured {
        write!(out, " {} |", label(criterion))?;
    }
    out.write_all(b"\n|---|")?;
    out.write_all(&b"---:|".repeat(summary.measured.len()))?;
    out.write_all(b"\n")?;
    for (name, _, group) in &summary.groups {
        write!(out, "| {name} |")?;
        for &criterion in &summary.measured {
            let stats = group.get(criterion);
            write!(out, " {} |", ratio(&stats, stats.percent()))?;
        }
        out.write_all(b"\n")?;
    }
    out.write_all(b"\n")
}

fn file_section(out: &mut Vec<u8>, summary: &Summary<'_>, file: &FileReport<'_>) -> io::Result<()> {
    write!(out, "\n### `{}`\n\n", file.file.name)?;
    totals(out, summary, |criterion| file.stats.with_percent(criterion))?;
    let lines: Vec<u32> = file.lines().filter(Line::missed).map(|line| line.number).collect();
    if !lines.is_empty() {
        writeln!(out, "\nLines never run: {}.", ranges(&lines))?;
    }
    // By line: `208 then, 306 then else`.
    let mut branches: Vec<(u32, &str)> = file
        .reported_branches()
        .filter(Branch::missed)
        .map(|branch| (branch.report_line(), branch.kind))
        .collect();
    branches.sort_by_key(|&(line, _)| line);
    if !branches.is_empty() {
        let mut lines: Vec<String> = Vec::new();
        for chunk in branches.chunk_by(|a, b| a.0 == b.0) {
            let kinds: Vec<&str> = chunk.iter().map(|&(_, kind)| kind).collect();
            lines.push(format!("{} `{}`", chunk[0].0, kinds.join(" ")));
        }
        writeln!(out, "\nBranches never taken: {}.", lines.join(", "))?;
    }
    let methods: Vec<String> = file
        .methods()
        .filter(MethodReport::missed)
        .map(|method| {
            let method = method.method;
            format!("`{}#{}` at {}", method.owner, method.name, method.span.start_line)
        })
        .collect();
    if !methods.is_empty() {
        writeln!(out, "\nMethods never called: {}.", methods.join(", "))?;
    }
    excerpt(out, file, &lines)
}

/// The missed lines, numbered, a `…` between runs.
fn excerpt(out: &mut Vec<u8>, file: &FileReport<'_>, missed: &[u32]) -> io::Result<()> {
    if missed.is_empty() {
        return Ok(());
    }
    let shown = &missed[..missed.len().min(EXCERPT)];
    let texts: Vec<(u32, String)> = file
        .lines()
        .filter(|line| shown.binary_search(&line.number).is_ok())
        .map(|line| (line.number, String::from_utf8_lossy(chomp(line.text)).into_owned()))
        .collect();
    // A fence longer than any run of backticks in the code.
    let longest = texts.iter().map(|(_, text)| longest_run(text, '`')).max().unwrap_or(0);
    let fence = "`".repeat(longest.max(2).strict_add(1));
    let width = shown.last().map_or(1, |last| last.to_string().len());
    let ruby = Path::new(&file.file.name).extension().is_some_and(|extension| extension == "rb");
    let language = if ruby { "ruby" } else { "" };
    write!(out, "\n{fence}{language}\n")?;
    let mut previous = None;
    for (number, text) in &texts {
        if previous.is_some_and(|previous: u32| previous.strict_add(1) != *number) {
            writeln!(out, "{:>width$}", "…")?;
        }
        writeln!(out, "{number:>width$}  {text}")?;
        previous = Some(*number);
    }
    if missed.len() > shown.len() {
        writeln!(out, "… {} more lines", missed.len().strict_sub(shown.len()))?;
    }
    writeln!(out, "{fence}")
}

fn totals(
    out: &mut Vec<u8>,
    summary: &Summary<'_>,
    stats: impl Fn(Criterion) -> (Stats, f64),
) -> io::Result<()> {
    let parts: Vec<String> = summary
        .measured
        .iter()
        .map(|&criterion| {
            let (stats, percent) = stats(criterion);
            format!("{} {}", label(criterion), ratio(&stats, percent))
        })
        .collect();
    writeln!(out, "{}", parts.join(" · "))
}

/// `83.83% (82782 / 98745)`
fn ratio(stats: &Stats, percent: f64) -> String {
    format!("{:.2}% ({} / {})", floor2(percent), stats.covered, stats.total())
}

const fn label(criterion: Criterion) -> &'static str {
    match criterion {
        Criterion::Line => "Lines",
        Criterion::Branch => "Branches",
        Criterion::Method => "Methods",
    }
}

/// What a file has left to cover.
const fn missed(file: &FileReport<'_>) -> u64 {
    let counts = &file.stats.counts;
    counts.line.missed.strict_add(counts.branch.missed).strict_add(counts.method.missed)
}

/// `[3, 4, 5, 9]` as `3-5, 9`.
fn ranges(numbers: &[u32]) -> String {
    let mut runs: Vec<(u32, u32)> = Vec::new();
    for &number in numbers {
        match runs.last_mut() {
            Some((_, end)) if end.strict_add(1) == number => *end = number,
            _ => runs.push((number, number)),
        }
    }
    let runs: Vec<String> = runs
        .iter()
        .map(
            |&(start, end)| if start == end { start.to_string() } else { format!("{start}-{end}") },
        )
        .collect();
    runs.join(", ")
}

fn longest_run(text: &str, character: char) -> usize {
    text.split(|other| other != character).map(str::len).max().unwrap_or(0)
}
