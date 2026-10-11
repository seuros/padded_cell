# frozen_string_literal: true

# Methods of classes whose name differs from process to process.
Square = Struct.new(:side) do
  def area = side * side
end

GREETER = Class.new do
  def hello = :hello

  def bye = :bye
end
