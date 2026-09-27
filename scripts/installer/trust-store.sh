#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

# Exit 78 means that Homebrew must handle this layout/configuration itself.
php_darwin_ruby - "$@" <<'PHP_DARWIN_TRUST_RUBY'
require 'json'
require 'fileutils'
require 'tempfile'

def unsupported
  exit 78
end

def secure_stat(path, directory: false)
  stat = File.lstat(path)
  unsupported if stat.symlink?
  raise "insecure trust path: #{path}" unless stat.uid == Process.euid && (stat.mode & 0022).zero?
  raise "invalid trust path: #{path}" unless directory ? stat.directory? : stat.file? && stat.nlink == 1
  stat
end

def atomic_write(path, contents)
  Tempfile.create(['.php-darwin-trust-', '.tmp'], File.dirname(path)) do |file|
    file.chmod(0600)
    file.write(contents)
    file.flush
    file.fsync
    File.rename(file.path, path)
  end
end

def read_store(path)
  return {} unless File.exist?(path) || File.symlink?(path)
  secure_stat(path)
  store = JSON.parse(File.read(path))
  # Unknown schemas belong to Homebrew. Never repair or replace malformed JSON.
  unsupported unless store.is_a?(Hash) && (store.keys - %w[trustedtaps trustedformulae trustedcasks trustedcommands]).empty?
  unsupported unless store.values.all? { |entries| entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(String) } }
  store
end

journal_written = false
store_written = false
begin
  mode, prefix, tap, journal, *references = ARGV
  raise 'invalid trust operation' unless %w[snapshot add remove].include?(mode)
  unsupported if Process.euid.zero? || ENV['HOMEBREW_FORCE_BREW_WRAPPER'] || ENV['HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY']
  repository = File.dirname(File.dirname(File.realpath(File.join(prefix, 'bin/brew'))))
  source_path = File.join(repository, 'Library/Homebrew/trust.rb')
  unsupported unless File.file?(source_path)
  source = File.read(source_path)
  # Only the JSON storage protocol with Homebrew's flock/atomic-write contract
  # is supported. Unrecognized storage implementations use the CLI instead.
  protocol = {
    'trust_file' => ['HOMEBREW_USER_CONFIG_HOME', '.homebrew/trust.json', 'user_config_home/"trust.json"'],
    'setting_key' => ['SETTING_KEYS.fetch(type).to_s'],
    'normalise_name' => ['name.downcase'],
    'trust_store' => ['JSON.parse(trust_path.read)', 'parsed_store.transform_values'],
    'write_trust_store' => ['write_path.atomic_write', 'write_path.chmod(0600)'],
    'with_trust_store_lock' => ['"#{trust_file}.lock"', 'File::RDWR | File::CREAT, 0600', 'lock_file.flock(File::LOCK_EX)']
  }
  protocol.each do |name, markers|
    method = source[/^    def self\.#{name}\b.*?^    end$/m]
    unsupported unless method && markers.all? { |marker| method.include?(marker) }
  end
  %w[tap:trustedtaps formula:trustedformulae cask:trustedcasks command:trustedcommands].each do |mapping|
    type, key = mapping.split(':')
    unsupported unless source.match?(/#{type}:\s+:#{key}\b/)
  end
  config_base = [ENV['XDG_CONFIG_HOME'], ENV['HOMEBREW_XDG_CONFIG_HOME']].find { |value| value && !value.empty? }
  config = config_base ? File.join(config_base, 'homebrew') : File.join(ENV.fetch('HOME'), '.homebrew')
  unsupported unless config.start_with?('/')
  # brew.env may redirect Homebrew or its config. Let brew resolve those files.
  ['/etc/homebrew/brew.env', File.join(prefix, 'etc/homebrew/brew.env'), File.join(config, 'brew.env')].each do |path|
    unsupported if File.exist?(path) || File.symlink?(path)
  end
  path = File.join(config, 'trust.json')
  secure_stat(config, directory: true) if File.exist?(config) || File.symlink?(config)
  if mode == 'snapshot'
    store = read_store(path)
    puts JSON.generate({ 'taps' => store.fetch('trustedtaps', []).map(&:downcase),
                         'formulae' => store.fetch('trustedformulae', []).map(&:downcase) })
    exit 0
  end
  raise 'invalid formula trust references' unless tap.match?(/\A[a-z0-9_.-]+\/[a-z0-9_.-]+\z/) &&
    references.all? { |name| name.start_with?(tap + '/') && name.match?(/\A[a-z0-9_.-]+\/[a-z0-9_.-]+\/[a-z0-9@+_.-]+\z/) }
  if mode == 'add'
    user, name = tap.split('/')
    tap_path = File.join(repository, 'Library/Taps', user, 'homebrew-' + name)
    origin = IO.popen(['git', '-C', tap_path, 'remote', 'get-url', 'origin'], &:read).strip.delete_suffix('.git')
    unsupported unless $?.success? && origin == "https://github.com/#{user}/homebrew-#{name}"
    references.each do |reference|
      formula = File.join(tap_path, 'Formula', reference.split('/').last + '.rb')
      unsupported unless File.file?(formula) && !File.symlink?(formula)
    end
  end
  FileUtils.mkdir_p(config, mode: 0700) unless File.exist?(config)
  secure_stat(config, directory: true)
  lock_path = path + '.lock'
  secure_stat(lock_path) if File.exist?(lock_path) || File.symlink?(lock_path)
  File.open(lock_path, File::RDWR | File::CREAT, 0600) do |lock|
    stat = secure_stat(lock_path)
    raise 'trust lock changed' unless stat.ino == lock.stat.ino && stat.dev == lock.stat.dev
    lock.flock(File::LOCK_EX)
    store = read_store(path)
    entries = store.fetch('trustedformulae', [])
    if mode == 'add'
      delta = references.uniq - entries.map(&:downcase)
      delta = [] if store.fetch('trustedtaps', []).map(&:downcase).include?(tap)
      # Record the delta under the same lock as the merge, including additions
      # by another process since the installer's initial trust snapshot.
      atomic_write(journal, delta.map { |entry| entry + "\n" }.join)
      journal_written = true
      unless delta.empty?
        store['trustedformulae'] = (entries + delta).sort
        atomic_write(path, JSON.pretty_generate(store) + "\n")
        store_written = true
      end
    else
      remaining = entries.reject { |entry| references.include?(entry.downcase) }
      unless entries == remaining
        remaining.empty? ? store.delete('trustedformulae') : store['trustedformulae'] = remaining
        if store.empty?
          File.unlink(path)
        else
          atomic_write(path, JSON.pretty_generate(store) + "\n")
        end
      end
    end
  end
rescue SystemCallError, JSON::ParserError, RuntimeError, ArgumentError, KeyError => error
  File.unlink(journal) if journal_written && !store_written && File.file?(journal)
  warn "php-darwin: trust store: #{error.message}"
  exit 1
end
PHP_DARWIN_TRUST_RUBY
