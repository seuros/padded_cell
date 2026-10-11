# frozen_string_literal: true

require_relative 'chart/delta'
require_relative 'chart/probe'
require_relative 'chart/raw'
require_relative 'chart/accumulator'
require_relative 'chart/filter'
require_relative 'chart/config'
require_relative 'chart/source_files'
require_relative 'chart/document'
require_relative 'chart/merge'
require_relative 'chart/report'

module PaddedCell
  # Built-in coverage: Ruby's Coverage measured in the
  # runner, every worker and every cell, summed exactly in the runner. The
  # chart, as the asylum keeps one per patient: inside, a name that is not
  # Ruby's own Coverage; outside, it is all --coverage.
  #
  # Measuring starts before the suite loads, so what is measured comes from
  # the command line (--coverage=lines,branches,methods,eval); the report is
  # configured in the test helper, with PaddedCell.coverage (see Config).
  module Chart
    CRITERIA = %i[lines branches methods eval].freeze
    DEFAULT_CRITERIA = %i[lines branches].freeze

    class << self
      # Every PaddedCell.coverage block, in one Config.
      def config = @config ||= Config.new

      def configure(profile = nil, &block)
        config.profile(profile) if profile
        config.instance_eval(&block) if block
        config
      end
    end
  end
end
