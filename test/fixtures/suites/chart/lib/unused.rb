# frozen_string_literal: true

# Tracked, never loaded: reported with every line and branch missed.
module Unused
  class Thing
    def call(value)
      return :none if value.nil?

      case value
      when Integer then value.positive? ? :positive : :negative
      else value&.to_s
      end
    end

    def self.build = new
  end
end
