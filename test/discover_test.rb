# frozen_string_literal: true

require_relative 'test_helper'

class DiscoverTest < Minitest::Test
  # The same .rb/.tsv pairs the Rust crate checks in core/tests/fixtures.rs,
  # through the extension's two entry points.
  def test_fixtures_match_their_expectations
    paths = Fixtures.discovery.keys

    assert_equal Fixtures.discovery.values, PaddedCellNative.discover_files(paths)
    Fixtures.discovery.each do |path, expected|
      assert_equal expected, PaddedCellNative.discover(File.read(path)), path
    end
  end

  # Half-written files: Prism recovers, discovery never raises. A test's
  # end line may be one past the cut.
  def test_every_truncated_prefix_of_the_fixtures
    Fixtures.discovery.each_key do |path|
      source = File.binread(path)
      (0..source.bytesize).each do |cut|
        rows = PaddedCellNative.discover(source.byteslice(0, cut))
        rows.each { |row| assert_operator row[2], :<=, row[3], "#{path} cut at #{cut}" }
      end
    end
  end

  def test_discovery_reads_files_into_test_refs
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'user_test.rb')
      File.write(file, "class UserTest < Minitest::Test\n  def test_valid\n  end\nend\n")
      ref = PaddedCell::Discovery.call([file]).first

      assert_equal 'UserTest#test_valid', ref.id
      assert_equal file, ref.file
      assert_equal 2..3, ref.lines
    end
  end

  def test_unreadable_files_raise_their_errno
    Dir.mktmpdir do |dir|
      missing = File.join(dir, 'missing_test.rb')
      error = assert_raises(Errno::ENOENT) { PaddedCell::Discovery.call([missing]) }

      assert_includes error.message, missing
    end
  end
end
