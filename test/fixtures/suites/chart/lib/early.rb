# frozen_string_literal: true

# Tracked. Loaded before coverage starts when a test asks (RUBYOPT=-r).
module Early
  def self.call = :early
end
