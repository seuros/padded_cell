# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'minitest/autorun'

if defined?(PaddedCell.coverage)
  PaddedCell.coverage do
    track 'lib/**/*.rb'
    group 'Core', 'lib/calc.rb'
    group('Lazy') { |file| file.filename.end_with?('lazy.rb') }
    # After every test: workers hand over often, cells then send what they
    # handed over sparse.
    flush_interval 0
    minimum line: Float(ENV['COVERAGE_MINIMUM']) if ENV['COVERAGE_MINIMUM']
    minimum_by_file line: Float(ENV['COVERAGE_MINIMUM_BY_FILE']) if ENV['COVERAGE_MINIMUM_BY_FILE']
    minimum_by_group 'Core', line: Float(ENV['COVERAGE_MINIMUM_CORE']) if ENV['COVERAGE_MINIMUM_CORE']
    maximum_drop line: Float(ENV['COVERAGE_MAXIMUM_DROP']) if ENV['COVERAGE_MAXIMUM_DROP']
    dir ENV['COVERAGE_DIR'] if ENV['COVERAGE_DIR']
    formats(*ENV['COVERAGE_FORMATS'].split(',')) if ENV['COVERAGE_FORMATS']
  end
end

require 'calc'
require 'shapes'
require 'directives'
autoload :Lazy, 'lazy'
