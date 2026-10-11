# frozen_string_literal: true

module PaddedCell
  module Chart
    # What filter and group blocks receive: a file of the report.
    class SourceFile
      attr_reader :filename, :project_filename

      def initialize(filename, project_filename)
        @filename = filename
        @project_filename = project_filename
      end

      # Its lines, as File.readlines gives them.
      def src = @src ||= File.readlines(filename)
      alias source src
    end

    # Filters and groups pick files by their path
    # relative to the project root:
    #
    #   "lib/"         a directory, anywhere along the path
    #   "app/models"   a path segment: app/models/user.rb, not app/models_old/
    #   "contract.rb"  a file name ending
    #   /regexp/       matched against the relative path
    #   [a, b]         any of them
    #   { |file| }     a block, given a SourceFile
    module Filter
      module_function

      # A callable taking a SourceFile.
      def build(argument = nil, &block)
        case argument || block
        when String then string(argument)
        when Regexp then ->(file) { argument.match?(file.project_filename) }
        when Array
          filters = argument.map { build(it) }
          ->(file) { filters.any? { it.call(file) } }
        when Proc then argument || block
        else raise ArgumentError, "a coverage filter is a String, Regexp, Array or block, not #{argument.inspect}"
        end
      end

      def string(argument)
        normalized = argument.delete_prefix('/')
        escaped = Regexp.escape(normalized)
        pattern = if normalized.end_with?('/') then %r{(?:\A|/)#{escaped}}
                  elsif normalized.include?('.') && !normalized.include?('/') then %r{[^/]*#{escaped}(?=[/.]|\z)}
                  else %r{(?:\A|/)#{escaped}(?=[/.]|\z)}
                  end
        ->(file) { pattern.match?(file.project_filename) }
      end
    end
  end
end
