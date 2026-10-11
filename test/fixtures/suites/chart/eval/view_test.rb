# frozen_string_literal: true

require_relative '../test/test_helper'
require 'erb'

# A template, compiled with its file name: with --coverage=eval, Ruby
# measures it like a source file.
class ViewTest < Minitest::Test
  def test_greeting
    path = File.expand_path('../lib/greeting.erb', __dir__)
    erb = ERB.new(File.read(path))
    erb.filename = path

    assert_equal "Hello Ann\n", erb.result_with_hash(name: 'Ann', loud: false)
  end
end
