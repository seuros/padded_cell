# frozen_string_literal: true

# Autoloaded by a test, after the fork: its cell (or worker) sends it dense.
module Lazy
  def self.call(flag)
    return :early if flag

    :late
  end

  def self.unused
    :unused
  end
end
