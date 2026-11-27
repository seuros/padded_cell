# frozen_string_literal: true

module PaddedCell
  # A statically discovered test.
  TestRef = Data.define(:file, :class_name, :name, :start_line, :end_line) do
    def id = "#{class_name}##{name}"

    def lines = start_line..end_line
  end

  # Static discovery, without loading anything.
  module Discovery
    module_function

    # TestRefs for files, in file order, then source order. The extension
    # reads and parses the files itself, on every core.
    def call(files) = PaddedCellNative.discover_files(files).zip(files).flat_map { |rows, file| refs(rows, file) }

    # TestRefs for one source string.
    def source(source, file: '(source)') = refs(PaddedCellNative.discover(source), file)

    def refs(rows, file) = rows.map { TestRef.new(file, *it) }

    # Names of the classes declared `abstract_test_case!` in files.
    def abstract_classes(files) = PaddedCellNative.abstract_classes(files)
  end
end
