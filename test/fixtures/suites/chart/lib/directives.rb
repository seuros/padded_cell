# frozen_string_literal: true

# Lines, branches and methods left out by directive comments.
module Directives
  def self.call(flag)
    # simplecov:disable branch
    value = flag ? :yes : :no
    # simplecov:enable branch
    report(value) if flag # simplecov:disable
    value
  end

  # simplecov:disable
  def self.report(value)
    warn(value.inspect)
  end
  # simplecov:enable

  def self.unused = :unused
end
