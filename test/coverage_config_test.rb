# frozen_string_literal: true

require_relative 'test_helper'
require 'padded_cell/chart'

class CoverageConfigTest < Minitest::Test
  Chart = PaddedCell::Chart

  # String filters match path segments, not substrings.
  def test_string_filters_match_path_segments
    {
      'lib/' => { 'lib/a.rb' => true, 'app/lib/a.rb' => true, 'mylib/a.rb' => false },
      'app/models' => { 'app/models/user.rb' => true, 'app/models_old/user.rb' => false,
                        'engines/app/models/x.rb' => true },
      'contract.rb' => { 'app/user_contract.rb' => true, 'app/contract.rbx' => false },
      '/vendor/bundle/' => { 'vendor/bundle/gems/x.rb' => true, 'vendor/bundler/x.rb' => false }
    }.each do |filter, cases|
      cases.each { |path, expected| assert_equal expected, matches?(filter, path), "#{filter} on #{path}" }
    end
  end

  def test_regexps_arrays_and_blocks
    assert matches?(/\Aapp/, 'app/a.rb')
    refute matches?(/\Aapp/, 'lib/app.rb')
    assert matches?(['config/', /\.rake\z/], 'lib/tasks/x.rake')
    filter = Chart::Filter.build { |file| file.filename.end_with?('_job.rb') }

    assert filter.call(Chart::SourceFile.new('/r/app/x_job.rb', 'app/x_job.rb'))
    assert_raises(ArgumentError) { Chart::Filter.build(42) }
  end

  def test_rails_profile_and_defaults
    config = Chart::Config.new
    config.profile(:rails)

    assert_equal ['{app,lib}/**/*.rb'], config.tracked
    assert_equal %w[Channels Controllers Helpers Jobs Libraries Mailers Models Views], config.groups.keys
    %w[config/routes.rb db/seeds.rb test/a_test.rb .hidden/x.rb vendor/bundle/x.rb].each do |path|
      assert skipped?(config, path), path
    end
    refute skipped?(config, 'app/models/user.rb')
    assert_raises(ArgumentError) { config.profile(:sinatra) }
  end

  def test_criteria_and_formats_are_checked
    config = Chart::Config.new

    assert_raises(ArgumentError) { config.enable_coverage(:branch) }
    assert_raises(ArgumentError) { config.formats(:lcov, :pdf) }
    config.clear_filters

    refute skipped?(config, 'test/a_test.rb')
  end

  # A file can be in several groups; files in none are Ungrouped, empty
  # groups are left out, and a group defined again replaces the first.
  def test_groups
    config = Chart::Config.new
    config.group('Models', 'lib/')
    config.group('Models', 'app/models')
    config.group('Users') { it.project_filename.include?('user') }
    config.group('Empty', 'nothing/')
    files = %w[app/models/user.rb app/models/post.rb lib/user_export.rb lib/other.rb]
            .to_h { [it, { lines: [], branches: nil, methods: nil }] }
    source_files = Chart::SourceFiles.new(files, config:, root: '/r')

    assert_equal %w[app/models/post.rb app/models/user.rb lib/other.rb lib/user_export.rb],
                 source_files.rows.map { it[1] }
    assert_equal [['Models', [0, 1]], ['Users', [1, 3]], ['Ungrouped', [2]]], source_files.groups
  end

  private

  def matches?(filter, path) = Chart::Filter.build(filter).call(Chart::SourceFile.new("/r/#{path}", path))

  def skipped?(config, path) = config.filters.any? { it.call(Chart::SourceFile.new("/r/#{path}", path)) }
end
