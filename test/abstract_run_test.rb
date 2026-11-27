# frozen_string_literal: true

require_relative 'test_helper'

# Minitest 6.1's abstract_test_case!, end to end.
class AbstractRunTest < Minitest::Test
  include CLIHelper

  # abstract_test_case! bases run none of their own tests, wherever they
  # are defined; their subclasses run them all.
  def test_abstract_test_cases_run_only_in_their_subclasses
    %w[test worker].each do |isolation|
      run = padded_cell('--no-timings', '--isolation', isolation, '-v', suite: 'abstract')

      assert_equal [4, 7, 0, 0, 0], run.summary, "#{isolation}: #{run.out}#{run.err}"
      assert_includes run.out, 'TriangleTest#test_has_sides'
      refute_match(/(ShapeTestCase|PolygonTest)#/, run.out)
    end
  end

  def test_listing_skips_abstract_test_cases
    run = padded_cell('--list', suite: 'abstract')

    assert_equal '', run.out
  end

  def test_spec_classes_named_by_description_run
    run = padded_cell('--no-timings', '-v', suite: 'abstract')

    assert_includes run.out, 'GET #index#test_0001_responds', run.err
  end
end
