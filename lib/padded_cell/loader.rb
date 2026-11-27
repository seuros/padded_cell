# frozen_string_literal: true

module PaddedCell
  # A test file that would not load.
  class LoadFailure < StandardError; end

  # Loads test files once, in the runner, so every worker and cell starts
  # from the same preloaded (copy-on-write) process.
  module Loader
    # Test helpers require minitest/autorun (or Rails' equivalent): its
    # at_exit would run the whole suite again, unisolated.
    module NoAutorun
      def autorun = nil
    end

    module_function

    def call(files, seed:)
      # An at_exit cannot be taken back: refuse rather than run twice.
      if Minitest.installed_at_exit?
        raise LoadFailure, 'minitest/autorun was required before padded_cell loaded the suite: its at_exit ' \
                           'would run every test again, unisolated. Drop it from RUBYOPT, or require ' \
                           "'minitest' instead where it runs before padded_cell"
      end
      Minitest.singleton_class.prepend(NoAutorun)
      Minitest.seed = seed
      # What `rake test` and `rails test` put on the load path.
      %w[test lib].each do |dir|
        path = File.expand_path(dir)
        $LOAD_PATH.unshift(path) if File.directory?(path) && !$LOAD_PATH.include?(path)
      end
      files.each { load_file(it) }
    end

    def load_file(file)
      require file
    rescue ScriptError, StandardError => e
      raise LoadFailure, "#{file}: #{e.class}: #{e.message}"
    end

    # [klass, method_name] for every loaded test, the way Minitest finds them.
    def tests
      runnables = Minitest::Runnable.runnables
      abstract = abstract_classes(runnables)
      runnables.flat_map do |klass|
        next [] if abstract.include?(klass.name)

        klass.runnable_methods.map { [klass, it] }
      rescue NotImplementedError
        []
      end
    end

    # Minitest's abstract_test_case! guards the class-level run, which cells
    # never call: the declaration is read from the files the classes were
    # defined in instead, test helpers and support files included.
    def abstract_classes(runnables)
      files = runnables.filter_map { source_file(it) }
      Discovery.abstract_classes(files.uniq.select { File.file?(it) }).to_set
    end

    CONSTANT_PATH = /\A[A-Z]\w*(::[A-Z]\w*)*\z/

    # Spec classes are named after their description ("GET #index"), which
    # is no constant: their methods say where they were defined.
    def source_file(klass)
      name = klass.name
      return unless name
      return Object.const_source_location(name)&.first if name.match?(CONSTANT_PATH)

      klass.instance_methods(false).lazy.filter_map { klass.instance_method(it).source_location&.first }.first
    end
  end

  # Which loaded tests run: Minitest's --include/--exclude, plus file:line.
  class Filter
    def initialize(selection, refs, include: nil, exclude: nil)
      @selection = selection
      @include = pattern(include)
      @exclude = pattern(exclude)
      @ends = refs.to_h { [[it.file, it.start_line], it.end_line] }
      @selected = selection.files.to_h { [it, true] }
    end

    def call(klass, name)
      matches_name?(klass, name) && (!@selection.line_filtered? || line_selected?(klass, name))
    end

    def matches_name?(klass, name)
      id = "#{klass}##{name}"
      return false if @include && !matches?(@include, name, id)
      return false if @exclude && matches?(@exclude, name, id)

      true
    end

    private

    # "/re/" is a Regexp, anything else an exact name, as in Minitest.
    def pattern(value)
      match = value.is_a?(String) && %r{\A/(.*)/\z}.match(value)
      match ? Regexp.new(match[1]) : value
    end

    def matches?(pattern, name, id) = [name, id].any? { pattern === it }

    # With file:line arguments, a test runs when its file was named and its
    # definition overlaps a requested line, or its file was named whole.
    def line_selected?(klass, name)
      file, line = klass.instance_method(name).source_location
      return false unless file && @selected[file]

      @selection.covers?(file, line..@ends.fetch([file, line], line))
    end
  end
end
