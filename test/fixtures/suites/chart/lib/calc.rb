# frozen_string_literal: true

# Loaded by the runner before it forks: cells send it sparse.
class Calc
  def add(left, right) = left + right

  def sign(number)
    if number.positive?
      :positive
    elsif number.negative?
      :negative
    else
      :zero
    end
  end

  def never_called
    :never
  end

  # :nocov:
  def debug
    warn inspect
  end
  # :nocov:

  def maybe(flag) = flag ? :yes : :no
end
