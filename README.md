# padded_cell

Your tests aren't crazy. They just need their own room.

padded_cell is a drop-in runner for Minitest and Rails test suites. Nothing in
your tests changes; padded_cell replaces the thing that runs them:

- **every test in its own forked cell**: a test that segfaults, calls `exit`,
  hangs, monkey patches `Time` or leaves a thread behind takes down its cell,
  not the run, and not the next test (Rails suites with fixtures default to
  sharing a worker instead, see [Isolation](#isolation));
- **workers fed whole classes**, slowest first from the timings of the
  previous run, so per-class setup such as fixtures happens once; idle
  workers split the remaining big classes;
- **static discovery** with Prism: `file:line`, `--list` and CI sharding work
  without loading a single test file;
- Minitest's own reporters and plugins, plus JUnit XML and JSON lines.

Discovery and scheduling are Rust, in a native extension: Prism parses the
test files on every core, and a deterministic scheduler orders the run.

```console
$ bundle exec padded_cell
Run options: --seed 33512 --isolation test

# Running:

.....E.......................................

Finished in 2.083220s, 21.6013 runs/s, 233.2927 assertions/s.

  1) Error:
PaymentTest#test_refund:
PaddedCell::CellCrashed: cell killed by SIGABRT
    test/models/payment_test.rb:41:in 'PaymentTest#test_refund'

45 runs, 486 assertions, 0 failures, 1 errors, 0 skips
```

One test segfaulted a C extension (Ruby aborts on a segfault) and took its cell
down. The other 44 never noticed.

## Installation

Requires CRuby 4.0 or newer and Minitest 6, on Linux, macOS or FreeBSD.
padded_cell is built on `fork`: Windows, JRuby and TruffleRuby are not
supported.

```ruby
group :test do
  gem "padded_cell"
end
```

Precompiled gems ship for Linux (x86_64 and aarch64; glibc 2.34+ such as
Debian 13, Ubuntu 26.04, RHEL 10, Fedora, Arch or Omarchy, plus musl for
Alpine), macOS 13+ (arm64, x86_64) and FreeBSD 15.1 (amd64): no Rust, no
compiler, nothing to build. Anything else (another CPU, an older glibc) gets
the source gem, which compiles the extension at install and needs Rust 1.99+.
padded_cell does not load without its extension.

## Usage

```console
$ padded_cell                              # test/**/*_test.rb, minus system, dummy and fixtures
$ padded_cell test/models                  # a directory
$ padded_cell test/models/user_test.rb:12  # the test spanning line 12
$ padded_cell user_test.rb:12-30:41        # tests overlapping 12..30, or spanning 41
$ padded_cell -n /refund/ -e test_slow     # Minitest's --include / --exclude
$ padded_cell -j 8 --seed 1234             # 8 workers, reproducible order
$ padded_cell --timeout 30                 # kill and fail anything running 30s
$ padded_cell --fail-fast
$ padded_cell --asylum                     # retry failures; report the flaky ones (see below)
$ padded_cell --list                       # what would run, without loading anything
$ padded_cell --shard 2/4                  # CI: the second quarter of the classes
$ padded_cell --junit tmp/junit.xml --json tmp/results.jsonl
$ padded_cell --coverage                   # line and branch coverage (see Coverage)
```

Exit status: 0 when everything passed, 1 otherwise, 2 for usage or load
errors, 3 when only coverage is below a threshold, 130 when interrupted.

### How a run works

1. **Select** files the way `rails test` does, `file:line` included.
2. **Discover** tests statically with Prism (`def test_*` and Rails'
   `test "..."` in classes inheriting from a `...Test` or `...TestCase`).
3. **Load** the test files once, in the runner. Workers and cells are forks of
   that process, so the app boots once, and copy-on-write shares its memory.
   `minitest/autorun` is neutralized, so the suite does not run again at exit.
4. **Order**: keep each class's tests together, as Minitest and Rails do.
   Shard by a stable hash of the class name, shuffle classes and tests with
   the seed, then put the slowest classes, and within them the slowest
   tests, first (`tmp/padded_cell/timings.tsv`).
5. **Run**: a worker takes a whole class; once no class is left to take, an
   idle worker splits off the second half of another worker's remainder.
   Each test sends back its `Minitest::Result`. A cell or worker that dies or
   times out becomes an error result.
6. **Report** through Minitest's own reporters and plugins.

Loaded tests are the source of truth: inherited, `define_method` and other
dynamic tests run even though static discovery cannot see them.

### Isolation

`--isolation test` forks a cell per test. Forking a preloaded process is
cheap, and order-dependent tests stop depending on order.

`--isolation worker` runs tests directly in the long-lived workers, like
Rails' `parallelize`. A worker that crashes or times out is still reported
and replaced.

The default is `test`, except when Active Record fixtures are loaded: a fork
discards Active Record's connection pool, and every test would reload its
fixtures, so those suites default to `worker`. The `Run options:` line shows
which one a run uses; `--isolation` overrides it.

### Flaky tests

`--asylum[=N]` gives failed tests up to N more attempts (default 2) once the
run is over: one test at a time, each in a fresh cell. A test that passes on
retry counts as passed, but padded_cell shows every attempt, its seed, and
what made the difference:

```console
4 runs, 4 assertions, 1 failures, 0 errors, 0 skips

You're not crazy, the world is. 2 tests failed, then passed:

  FlakyTest#test_passes_when_retried
    seed 1      lost the race
    seed 1      passed, alone → timing, contention or state left by other tests

  FlakyTest#test_depends_on_the_seed
    seed 1      unlucky seed.
    seed 1      unlucky seed. (alone)
    seed 15472  passed, alone → randomness or test order

It's not the world, it's the test:
  FlakyTest#test_always_fails failed all 3 attempts
```

The first retry keeps the run's seed and runs alone, so passing there points
at timing, contention or leftover state; later retries change the seed, so
passing only there points at randomness or order. A test that fails every
attempt keeps its first failure, and the run fails. JUnit reports carry a
`<flakyFailure>` per flaky test; JSON lines carry the attempts in a `flaky`
field, or an `asylum` field for a test that never passed.

### Hooks

For anything that must not be shared across forks:

```ruby
# test/test_helper.rb
PaddedCell.before_fork { Database.disconnect }
PaddedCell.after_fork { |worker| Database.connect("app_test_#{worker}") }
PaddedCell.cleanup { |worker| Database.drop("app_test_#{worker}") }
```

`before_fork` runs in the runner, `after_fork` and `cleanup` once per worker
(`0...jobs`). Cells run no hooks: they inherit their worker's state. A
failing `after_fork` fails every test of its worker; a failing `cleanup`
fails the run, even when every test passed.

## Coverage

Ruby's `Coverage`, measured in the runner, in every worker and in every
cell, and summed exactly: a parallel run reports the counts of a serial one.

```console
$ padded_cell --coverage test/                         # lines and branches
$ padded_cell --coverage=lines,branches,methods test/
$ PADDED_CELL_COVERAGE=1 bin/rails padded_cell
```

Measuring starts before the suite loads, so what is measured (`lines`,
`branches`, `methods`, and `eval` for templates, experimental) comes from the
command line. The report is configured in the test helper:

```ruby
# test/test_helper.rb
PaddedCell.coverage(:rails) do
  track "{app,lib}/**/*.rb"           # report files never loaded, at 0%
  skip "app/legacy/"                  # also `filter`
  group "Operations", "app/concepts"  # string, regexp, array or block
  group("Contracts") { |file| file.filename.include?("contract") }
  minimum line: 90, branch: 80
  minimum_by_file line: 50
  minimum_by_group "Operations", line: 95
  maximum_drop line: 1                # since the previous whole run
  formats :markdown, :lcov, :json
  dir "coverage"                      # --coverage-dir wins
end
```

- Paths are matched relative to the project root. A string matches whole
  path segments (`"app/models"` takes `app/models/user.rb`, not
  `app/models_old/`), `"lib/"` a directory anywhere, `"contract.rb"` a file
  name ending; a regexp matches the path; a block gets the file
  (`filename`, `project_filename`, `src`).
- Left out by default: `vendor/bundle`, hidden files, `test/`, `spec/`,
  `features/`. `clear_filters` drops these.
- `:rails` skips `config/` and `db/`, groups `app/channels`,
  `app/controllers`, `app/helpers`, `app/jobs` and `app/workers`, `lib/`,
  `app/mailers`, `app/models` and `app/views`, and tracks
  `{app,lib}/**/*.rb`. A file in no group is Ungrouped.
- Thresholds compare percents floored to 2 decimals.

`PaddedCell.coverage` configures only; without `--coverage` nothing is
measured. Outside padded_cell, guard it with `if defined?(PaddedCell.coverage)`.

Into `coverage/` go, by format:

- `markdown`: `coverage.md`, for agents, reviews and CI summaries
  (`cat coverage/coverage.md >> $GITHUB_STEP_SUMMARY`): the totals and
  groups, then every file with code that never ran, the most missed first,
  with its missed lines, branches and methods, and that code. It stops
  listing files at 1 MB, the size of a GitHub job summary.
- `lcov`: `lcov.info` (`SF:./path`), for CI and editors.
- `json`: `coverage.json` and `.resultset.json`, in SimpleCov's formats, for
  the tools reading them.

Also, every run: `.padded_cell.json` (what the report is made of, and what
`--coverage-merge` reads), and after a whole passing run `.last_run.json`.

Lines and branches inside `# :nocov:` blocks, and under
`# simplecov:disable [line|branch|method]` / `# simplecov:enable` comments,
are skipped. A directive after code skips its own line.

A run below a threshold exits 3. Thresholds hold for a whole, passing,
complete run only: they are not checked when tests failed, when tests were
picked by name or line, under `--shard`, or when a worker or cell died
before handing over what it measured (the report then says it is partial).
Reports are written either way, failing runs included.

A suite that starts SimpleCov as well is refused (exit 2): two tools cannot
share Ruby's `Coverage`.

### Shards

Each shard reports on its own; merge them, at the same commit, without
running anything:

```console
$ padded_cell --coverage --coverage-dir coverage/1 --shard 1/2 test/   # machine 1
$ padded_cell --coverage --coverage-dir coverage/2 --shard 2/2 test/   # machine 2
$ padded_cell --coverage-merge coverage/1,coverage/2 --coverage-dir coverage
```

The merge refuses files that differ between shards or from the checkout,
and checks thresholds when every shard of the run is there. Lines that run
while the suite loads count once per shard.

### Cost

Measuring is opt-in: Ruby's instrumentation slows tests down. On a Rails
suite of 6,300 tests, lines and branches took the run from 465 s to 638 s of
CPU.

A worker hands over what it measured every 10 seconds or more: each time,
Ruby copies the coverage of every file it loaded, gems included (a few
milliseconds in a small app, a few hundred in a big Rails one), so the
interval stretches to keep this under 1% of the worker's time. A worker that
dies loses what it measured since. With `--isolation test` every cell pays
one such copy, at its end.

Files never loaded report their branches in the order Ruby compiles them.
With `eval`, code that `class_eval` runs from a heredoc counts as lines of
its file; directives in templates are not read.

## Rails

Nothing to configure. ActiveSupport's parallelization hooks run around
padded_cell's workers as they would around Rails' own: `parallelize_setup`,
`parallelize_teardown`, `parallelize_before_fork`, and Active Record's
per-worker test databases (`app_test-0`, `app_test-1`...).
`ActiveSupport::TestCase.parallel_worker_id` is set. A
`parallelize(workers: ...)` call in `test_helper.rb` stays inert, since
padded_cell is the executor.

```console
$ bin/rails padded_cell ARGS="-j 8 test/models"
```

Rails suites with fixtures run with `--isolation worker` unless told
otherwise (see [Isolation](#isolation)).

For coverage, see [Coverage](#coverage).

## Library

The engine-backed parts load without Minitest:

```ruby
require "padded_cell"

PaddedCell::Discovery.call(Dir["test/**/*_test.rb"]).map { [it.id, it.lines] }
# => [["UserTest#test_valid", 10..12], ...]

PaddedCell::Scheduler.batches(class_names, durations: seconds, seed: 42, shard: [0, 4])
# => [[test indices of one class], ...] in run order
```

## Rust

The extension lives in `ext/padded_cell_native`: `core` does discovery and
scheduling in plain Rust (no Ruby types), `ffi` binds it to Ruby. Neither is
published as a crate.

## Development

Needs Rust 1.99+ (`mise install` reads `mise.toml`).

```console
bundle install
rake test:all        # cargo test, then this suite run by padded_cell itself
rake dogfood         # this suite, run by padded_cell (compiles the extension first)
rake test            # this suite on plain Minitest, for when padded_cell itself is broken
rake lint            # dictator, cargo fmt --check, clippy
```

## License

MIT
