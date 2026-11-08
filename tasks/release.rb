# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'rubygems/package'
require 'tmpdir'
require_relative '../lib/padded_cell/version'

# Publishing what the release workflow built: the gems attached to the GitHub
# release, never whatever happens to sit in pkg/. Each is checked against the
# SHA-256 GitHub recorded when the workflow uploaded it, and against its own
# spec, before anything reaches RubyGems.
module PaddedCellRelease
  ROOT = File.expand_path('..', __dir__)
  REPOSITORY = 'seuros/padded_cell'
  HOST = 'https://rubygems.org'
  Artifact = Data.define(:path, :platform, :sha256)
  # gh honors CLICOLOR_FORCE even when piped: its JSON would carry escapes.
  PLAIN = { 'CLICOLOR_FORCE' => nil, 'FORCE_COLOR' => nil, 'NO_COLOR' => '1' }.freeze
  class Error < StandardError; end

  module_function

  def version(tag = nil)
    value = (tag || PaddedCell::VERSION).delete_prefix('v')
    unless Gem::Version.correct?(value) && Gem::Version.new(value).to_s == value
      raise Error, 'use a canonical gem version or v-prefixed release tag'
    end

    value
  end

  # {gem file name => sha256} for the release's gems, as GitHub recorded them.
  def digests(release_version)
    out, status = Open3.capture2(PLAIN, 'gh', 'api', "repos/#{REPOSITORY}/releases/tags/v#{release_version}")
    raise Error, "GitHub release v#{release_version} not found" unless status.success?

    JSON.parse(out).fetch('assets').filter_map do |asset|
      next unless asset['name'].match?(/\Apadded_cell-#{Regexp.escape(release_version)}(-[^\/\\\s]+)?\.gem\z/)

      sha256 = asset['digest'].to_s.delete_prefix('sha256:')
      raise Error, "no SHA-256 digest for #{asset['name']}" unless sha256.match?(/\A[a-f0-9]{64}\z/)

      [asset['name'], sha256]
    end.to_h
  end

  def verify(directory, release_version, expected)
    files = Dir.children(directory).grep(/\.gem\z/).sort
    raise Error, 'release gems and GitHub digests differ' if files.empty? || files != expected.keys.sort

    artifacts = files.map do |name|
      path = File.join(directory, name)
      raise Error, "checksum mismatch: #{name}" unless Digest::SHA256.file(path).hexdigest == expected.fetch(name)

      package = Gem::Package.new(path)
      package.verify
      spec = package.spec
      unless spec.name == 'padded_cell' && spec.version.to_s == release_version && spec.file_name == name
        raise Error, "unexpected release gem: #{name}"
      end
      Artifact.new(path:, platform: spec.platform.to_s, sha256: expected.fetch(name))
    end
    raise Error, 'release has no source gem' unless artifacts.any? { it.platform == 'ruby' }

    artifacts.sort_by { [it.platform == 'ruby' ? 0 : 1, it.platform] }
  rescue Errno::ENOENT, Gem::Package::Error => e
    raise Error, e.message
  end

  # Downloads and verifies the release's gems into pkg/.
  def fetch(tag = nil)
    release_version = version(tag)
    expected = digests(release_version)
    destination = File.join(ROOT, 'pkg')
    FileUtils.mkdir_p(destination)
    Dir.mktmpdir('padded_cell-release') do |directory|
      downloaded = system(PLAIN, 'gh', 'release', 'download', "v#{release_version}", '--repo', REPOSITORY,
                          '--pattern', "padded_cell-#{release_version}*.gem", '--dir', directory)
      raise Error, 'GitHub release download failed' unless downloaded

      verify(directory, release_version, expected).map do |artifact|
        path = File.join(destination, File.basename(artifact.path))
        FileUtils.cp(artifact.path, path)
        artifact.with(path:)
      end.tap { puts "Verified #{it.size} gems for v#{release_version} in #{destination}" }
    end
  end

  def published_versions
    uri = URI("#{HOST}/api/v1/versions/padded_cell.json")
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 15) do |http|
      http.get(uri.request_uri)
    end
    return [] if response.code == '404'
    raise Error, "RubyGems version lookup returned HTTP #{response.code}" unless response.code == '200'

    document = JSON.parse(response.body)
    raise Error, 'invalid RubyGems version response' unless document.is_a?(Array) && document.all?(Hash)

    document
  end

  # A partial publication resumes, but never replaces a published
  # version/platform with different bytes.
  def pending(artifacts, versions, release_version)
    artifacts.reject do |artifact|
      existing = versions.find { it['number'] == release_version && it['platform'] == artifact.platform }
      next false unless existing
      unless existing['sha'] == artifact.sha256
        raise Error, "RubyGems already has different bytes for #{artifact.platform}"
      end

      puts "Already published: #{File.basename(artifact.path)}"
      true
    end
  end

  def push_all(tag = nil)
    release_version = version(tag)
    artifacts = pending(fetch(tag), published_versions, release_version)
    require 'bundler'
    artifacts.each do |artifact|
      pushed = Bundler.with_unbundled_env { system(Gem.ruby, '-S', 'gem', 'push', artifact.path, '--host', HOST) }
      raise Error, "not pushed: #{File.basename(artifact.path)}; rerun gem:push_all to resume" unless pushed
    end
    puts "All release gems published for v#{release_version}"
  end
end
