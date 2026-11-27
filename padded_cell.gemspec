# frozen_string_literal: true

require_relative 'lib/padded_cell/version'

Gem::Specification.new do |spec|
  # Set by `rake gem:native`: the gem then carries the prebuilt extension for
  # that platform. Unset, it is the source gem, which compiles it at install.
  platform = ENV.fetch('PADDED_CELL_PLATFORM', nil)

  spec.name = 'padded_cell'
  spec.version = PaddedCell::VERSION
  spec.authors = ['Abdelkader Boudih']
  spec.email = ['terminale@gmail.com']

  spec.summary = 'A drop-in Minitest runner: every test in its own padded cell.'
  spec.description = 'Runs existing Minitest and Rails test suites with fork-per-test isolation, crash and ' \
                     'timeout containment, seeded timing-aware scheduling and sharding. Discovery and scheduling ' \
                     'are a Rust extension, precompiled for Linux, macOS and FreeBSD.'
  spec.homepage = 'https://github.com/seuros/padded_cell'
  spec.license = 'MIT'

  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['bug_tracker_uri'] = "#{spec.homepage}/issues"
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/master/CHANGELOG.md"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir[
    'lib/**/*.{rb,yml}',
    'exe/*',
    'README.md',
    'CHANGELOG.md',
    'LICENSE.txt'
  ]
  spec.bindir = 'exe'
  spec.executables = ['padded_cell']
  spec.require_paths = ['lib']

  # A runner for Minitest suites: it drives Minitest's own test and reporter classes.
  spec.add_dependency 'minitest', '~> 6.1'

  if platform
    spec.platform = Gem::Platform.new(platform)
    spec.files += Dir['lib/padded_cell/[0-9]*/padded_cell_native.{so,bundle}']
    # The binary is built for one Ruby ABI; newer Rubies get the source gem.
    spec.required_ruby_version = ['>= 4.0', '< 4.1.dev']
  else
    # Discovery and scheduling are Rust: without a precompiled gem for the
    # platform, the extension builds at install (Rust 1.99+ and rb_sys).
    spec.files += Dir['Cargo.toml', 'Cargo.lock', 'ext/padded_cell_native/extconf.rb',
                      'ext/padded_cell_native/{core,ffi}/Cargo.toml', 'ext/padded_cell_native/{core,ffi}/src/**/*.rs',
                      'ext/padded_cell_native/core/README.md']
    spec.extensions = ['ext/padded_cell_native/extconf.rb']
    spec.add_dependency 'rb_sys', '~> 0.9.130'
    spec.required_ruby_version = '>= 4.0'
  end
end
