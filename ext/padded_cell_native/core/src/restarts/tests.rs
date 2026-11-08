use super::*;

const SECOND: u64 = 1_000_000_000;

#[test]
fn scales_with_jobs_above_a_floor() {
    assert_eq!(Restarts::new(1).limit(), 16);
    assert_eq!(Restarts::new(8).limit(), 32);
    assert_eq!(Restarts::new(100_000).limit(), 1023);
}

#[test]
fn gives_up_past_the_limit_inside_the_window_and_stays_down() {
    let mut restarts = Restarts::new(1);
    for death in 0..16 {
        assert!(restarts.died(death), "death {death}");
    }
    assert!(!restarts.died(16));
    // A supervisor that gave up does not change its mind.
    assert!(!restarts.died(WINDOW_NS * 10));
}

#[test]
fn deaths_spread_over_time_never_give_up() {
    let mut restarts = Restarts::new(1);
    for death in 0..1_000 {
        assert!(restarts.died(death * SECOND), "death {death}");
    }
}
