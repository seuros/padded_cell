use super::*;

const fn stats(covered: u64, missed: u64, hits: u64) -> Stats {
    Stats { covered, missed, omitted: 0, hits }
}

#[test]
fn percent_and_strength() {
    const CASES: &[(Stats, f64, f64)] = &[
        (stats(0, 0, 0), 100.0, 0.0),
        (stats(3, 0, 6), 100.0, 2.0),
        (stats(0, 4, 0), 0.0, 0.0),
        (stats(2, 1, 9), 200.0 / 3.0, 3.0),
    ];
    for (stats, percent, strength) in CASES {
        assert_eq!(stats.percent().to_bits(), percent.to_bits(), "{stats:?}");
        assert_eq!(stats.strength().to_bits(), strength.to_bits(), "{stats:?}");
    }
}

#[test]
fn stats_sum() {
    let total: Stats = [stats(1, 2, 3), stats(4, 5, 6)].into_iter().sum();
    assert_eq!(total, stats(5, 7, 9));
    assert_eq!(total.total(), 12);
}

/// Values from Ruby's `Float#floor(2)`.
#[test]
fn floor2_is_rubys_float_floor() {
    const CASES: &[(f64, f64)] = &[
        (0.29, 0.29),
        (89.999, 89.99),
        (100.0, 100.0),
        (0.0, 0.0),
        (200.0 / 3.0, 66.66),
        (0.001, 0.0),
        (57.142_857_142_857_14, 57.14),
    ];
    for (number, expected) in CASES {
        assert_eq!(floor2(*number).to_bits(), expected.to_bits(), "number: {number}");
    }
}

#[test]
fn unmeasured_files_are_at_zero_until_covered() {
    let mut file = FileStats { unmeasured_branches: true, ..FileStats::default() };
    assert_eq!(file.percent(Criterion::Branch).to_bits(), 0.0_f64.to_bits());
    assert_eq!(file.percent(Criterion::Line).to_bits(), 100.0_f64.to_bits());
    file.unmeasured_branches = false;
    assert_eq!(file.percent(Criterion::Branch).to_bits(), 100.0_f64.to_bits());
}
