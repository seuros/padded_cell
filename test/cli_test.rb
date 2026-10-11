# frozen_string_literal: true

require_relative 'test_helper'

class CLITest < Minitest::Test
  include CLIHelper

  def test_version
    run = padded_cell('--version', suite: 'basic')

    assert_equal "padded_cell #{PaddedCell::VERSION}\n", run.out
  end

  def test_help
    run = padded_cell('--help', suite: 'basic')

    assert_predicate run.status, :success?
    assert_includes run.out, 'Usage: padded_cell [options] [paths...]'
  end

  def test_refuses_to_run_without_fork
    script = "Process.singleton_class.undef_method(:fork); ARGV.replace(%w[--no-timings]); load #{EXE.dump}"
    out, err, status = Open3.capture3(RbConfig.ruby, '-I', LIB, '-e', script,
                                      chdir: File.join(Fixtures::SUITES, 'basic'))

    assert_equal 2, status.exitstatus
    assert_equal "padded_cell: padded_cell needs fork, which this Ruby does not have\n", err
    assert_empty out
  end

  def test_usage_errors_exit_2
    [
      [%w[--bogus], 'invalid option: --bogus'],
      [%w[--shard 0/3], '--shard 0/3 (expected I/N, 1 <= I <= N)'],
      [%w[--isolation cage], 'invalid argument: --isolation cage'],
      [%w[-j 0], 'invalid argument: -j 0 (must be positive)'],
      [%w[--timeout -1], 'invalid argument: --timeout -1.0 (must be positive)'],
      [%w[--seed -1], 'invalid argument: --seed -1 (must be 0 to 2**64 - 1)'],
      [%W[--seed #{2**64}], "invalid argument: --seed #{2**64} (must be 0 to 2**64 - 1)"],
      [%w[test/missing_test.rb], 'no such test file: test/missing_test.rb'],
      [['-n', '/[/'], 'padded_cell: premature end of char-class: /[/'],
      [['--list', '-e', '/[/'], 'padded_cell: premature end of char-class: /[/']
    ].each do |args, message|
      run = padded_cell(*args, suite: 'basic')

      assert_equal 2, run.exitstatus, args.inspect
      assert_includes run.err, message
    end
  end
end
