# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'minitest/test_task'
require_relative 'tasks/release'

GEMSPEC = Gem::Specification.load('padded_cell.gemspec')
CARGO_MANIFEST = 'Cargo.toml'
# RbSys::ExtensionTask would point cargo at ext_dir (where extconf.rb lives);
# the crate itself is in ffi/.
ENV['RB_SYS_CARGO_MANIFEST_DIR'] ||= File.expand_path('ext/padded_cell_native/ffi', __dir__)

require 'rb_sys/extensiontask'

RbSys::ExtensionTask.new('padded_cell_native', GEMSPEC) do |ext|
  ext.ext_dir = 'ext/padded_cell_native'
  ext.lib_dir = 'lib/padded_cell'
end

# Plain Minitest: for when padded_cell itself is broken. CI and test:all run
# the suite with padded_cell (dogfood).
Minitest::TestTask.create(:test) do |t|
  t.test_globs = ['test/*_test.rb'] # test/fixtures holds suites padded_cell runs
end
# The suite needs the extension: build it first.
task test: :compile

namespace :test do
  desc 'cargo test for the padded_cell crate'
  task :rust do
    sh 'cargo', 'test', '--manifest-path', CARGO_MANIFEST, '--package', 'padded_cell'
  end

  desc 'The Rust crate, then this suite run by padded_cell itself'
  task all: %i[rust dogfood]
end

desc 'Run this suite with padded_cell itself, from this checkout'
task dogfood: :compile do
  # No paths: test/**/*_test.rb minus test/fixtures, whose suites the tests run
  sh FileUtils::RUBY, '-Ilib', 'exe/padded_cell'
end

desc 'dictator, cargo fmt --check and clippy'
task :lint do
  sh 'dictator', 'lint', '.'
  sh 'cargo', 'fmt', '--manifest-path', CARGO_MANIFEST, '--all', '--check'
  # build.warnings, not -D warnings: same gate, no flags passed to the compiler
  sh({ 'CARGO_BUILD_WARNINGS' => 'deny' },
     'cargo', 'clippy', '--manifest-path', CARGO_MANIFEST, '--workspace', '--all-targets')
end

namespace :gem do
  desc 'Build the source gem (compiles the extension at install; for platforms without a native gem)'
  task source: :build

  # A task argument, not PADDED_CELL_PLATFORM: set for the whole rake process, that
  # would turn the gemspec into a platform gem for compile's bundler/setup too.
  desc 'Build the precompiled gem for this machine (gem:native[platform] overrides the platform)'
  task :native, [:platform] => :compile do |_task, args|
    ruby_abi = RUBY_VERSION[/\A\d+\.\d+/]
    binary = "padded_cell_native.#{RbConfig::CONFIG['DLEXT']}"
    staged = "lib/padded_cell/#{ruby_abi}/#{binary}"
    local = Gem::Platform.local
    # A darwin version would limit the gem to that one macOS release.
    platform = args[:platform] || (local.os == 'darwin' ? "#{local.cpu}-darwin" : local.to_s)

    mkdir_p File.dirname(staged)
    cp "lib/padded_cell/#{binary}", staged
    mkdir_p 'pkg'
    Bundler.with_unbundled_env do
      sh({ 'PADDED_CELL_PLATFORM' => platform }, 'gem', 'build', 'padded_cell.gemspec',
         '--output', "pkg/padded_cell-#{GEMSPEC.version}-#{platform}.gem")
    end
  ensure
    rm_rf File.dirname(staged) if staged
  end

  desc 'Fetch and digest-verify the GitHub release gems into pkg/ (default: this version)'
  task :fetch, [:tag] do |_task, args|
    PaddedCellRelease.fetch(args[:tag])
  end

  desc 'Fetch the verified release gems and push every platform to RubyGems (resumable)'
  task :push_all, [:tag] do |_task, args|
    PaddedCellRelease.push_all(args[:tag])
  end
end

task default: 'test:all'

# Bundler's release would push only the source gem.
Rake::Task['release'].clear
desc 'Release: tag, then push the gems built by the release workflow (rake gem:push_all)'
task :release do
  abort 'Use the release workflow (push a v* tag), then `rake gem:push_all`'
end
