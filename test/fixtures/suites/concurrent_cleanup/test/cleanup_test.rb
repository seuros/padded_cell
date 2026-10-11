# frozen_string_literal: true

require 'minitest/autorun'
require 'padded_cell'

reader, writer = IO.pipe
PaddedCell.cleanup do |worker|
  if worker.zero?
    raise 'another worker did not start cleanup' unless IO.select([reader], nil, nil, 5)

    reader.read(1)
  else
    writer.write('.')
  end
end

class ConcurrentCleanupTest < Minitest::Test
  2.times do |i|
    define_method(:"test_#{i}") { assert true }
  end
end
