use std::io::{self, Write};

use super::FileReport;

/// Writes `reports` as an LCOV tracefile:
///
/// ```text
/// SF:./app/models/user.rb
/// DA:3,1                  each line of code outside :nocov: blocks
/// LF:12                   lines of code, those in :nocov: blocks included
/// LH:9                    lines covered
/// BRDA:4,0,1,2            each branch outside blocks: line, 0, number, hits
/// BRDA:6,0,2,-            ("-" for none)
/// end_of_record
/// ```
///
/// An empty `DA` or `BRDA` section leaves an empty line.
///
/// # Errors
///
/// What writing to `out` returns.
pub fn write_lcov(reports: &[FileReport<'_>], out: &mut impl Write) -> io::Result<()> {
    for report in reports {
        writeln!(out, "SF:./{}", report.file.name)?;
        let (mut code, mut covered, mut first) = (0_u64, 0_u64, true);
        for line in report.lines() {
            code = code.strict_add(u64::from(line.hits.is_some()));
            covered = covered.strict_add(u64::from(line.covered()));
            if let Some(hits) = line.hits
                && !line.skipped
            {
                if !first {
                    out.write_all(b"\n")?;
                }
                first = false;
                write!(out, "DA:{},{hits}", line.number)?;
            }
        }
        write!(out, "\nLF:{code}\nLH:{covered}\n")?;
        for (number, branch) in (1_u64..).zip(report.reported_branches()) {
            if number > 1 {
                out.write_all(b"\n")?;
            }
            write!(out, "BRDA:{},0,{number},", branch.report_line())?;
            if branch.hits == 0 { out.write_all(b"-")? } else { write!(out, "{}", branch.hits)? }
        }
        out.write_all(b"\nend_of_record\n")?;
    }
    Ok(())
}
