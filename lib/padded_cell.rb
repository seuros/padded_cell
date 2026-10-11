# frozen_string_literal: true

require_relative 'padded_cell/version'
require_relative 'padded_cell/native'
require_relative 'padded_cell/discovery'
require_relative 'padded_cell/scheduler'
require_relative 'padded_cell/selection'
require_relative 'padded_cell/hooks'

# A drop-in Minitest runner: every test in its own padded cell.
#
# The runner itself lives in padded_cell/runner (loaded by the padded_cell
# command). This file only holds what the Rust extension backs, which loads
# nothing else: static discovery and scheduling.
#
#   PaddedCell::Discovery.call(Dir["test/**/*_test.rb"]).map(&:id)
#   # => ["UserTest#test_valid", ...]
module PaddedCell
  class << self
    # See Hooks.
    def before_fork(&) = Hooks.before_fork(&)

    def after_fork(&) = Hooks.after_fork(&)

    def cleanup(&) = Hooks.cleanup(&)

    # Configures the coverage report (see Chart::Config). Inert unless
    # padded_cell runs with --coverage. A helper also run without
    # padded_cell guards it: `if defined?(PaddedCell.coverage)`.
    def coverage(profile = nil, &)
      require_relative 'padded_cell/chart'
      Chart.configure(profile, &)
    end
  end
end

require_relative 'padded_cell/railtie' if defined?(Rails::Railtie)
