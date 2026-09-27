#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

php_darwin_ruby - "$@" <<'PHP_DARWIN_UNLINK_RUBY'
require 'json'
require 'find'
require 'fileutils'
require 'tempfile'

def unsupported
  exit 78
end

def resolved(path)
  File.symlink?(path) ? File.expand_path(File.readlink(path), File.dirname(path)) : path
end

def parents_safe(prefix, path)
  parent = File.dirname(path)
  until parent == prefix
    raise "unsafe unlink parent: #{parent}" if File.symlink?(parent)
    raise 'unlink path outside Homebrew' unless parent.start_with?(prefix + '/')
    parent = File.dirname(parent)
  end
end

def acquire_lock(prefix, name, locks)
  raise 'invalid formula lock name' unless !%w[. ..].include?(name) && name.match?(/\A[a-zA-Z0-9@+_.-]+\z/)
  lock_path = File.join(prefix, 'var/homebrew/locks', name + '.formula.lock')
  parents_safe(prefix, lock_path)
  FileUtils.mkdir_p(File.dirname(lock_path))
  unsupported if File.symlink?(lock_path)
  file = File.open(lock_path, File::RDWR | File::CREAT, 0644)
  locks << file
  raise "Homebrew formula is busy: #{name}" unless file.flock(File::LOCK_EX | File::LOCK_NB)
  raise 'Homebrew formula lock changed' unless file.stat.ino == File.stat(lock_path).ino
end

locks = []
begin
  mode, prefix, journal_dir, *names = ARGV
  raise 'invalid unlink operation' unless %w[unlink restore].include?(mode)
  unsupported unless File.realpath(prefix) == prefix
  if mode == 'restore'
    journals = Dir.glob(File.join(journal_dir, '*.json')).sort.reverse
    restored_names = journals.flat_map do |journal|
      JSON.parse(File.read(journal)).flat_map do |entry|
        path = File.join(prefix, entry.fetch('path'))
        target = File.expand_path(entry.fetch('target'), File.dirname(path))
        match = target.match(%r{\A#{Regexp.escape(prefix)}/Cellar/([^/]+)/})
        raise 'invalid unlink journal target' unless match
        names = [match[1]]
        names << File.basename(path) if File.dirname(path) == File.join(prefix, 'opt') ||
          File.dirname(path) == File.join(prefix, 'var/homebrew/linked')
        names
      end
    end
    restored_names.uniq.sort.each { |name| acquire_lock(prefix, name, locks) }
    journals.each do |journal|
      JSON.parse(File.read(journal)).reverse_each do |entry|
        relative, target = entry.values_at('path', 'target')
        raise 'invalid unlink journal' unless relative.is_a?(String) && target.is_a?(String) &&
          relative.match?(%r{\A(?:(?:bin|etc|include|lib|sbin|share|var)/|opt/[^/]+\z)}) &&
          !relative.match?(%r{(?:\A|/)\.\.?(/|\z)|//|[\r\n\t]}) &&
          File.expand_path(target, File.dirname(File.join(prefix, relative))).start_with?(prefix + '/Cellar/')
        path = File.join(prefix, relative)
        parents_safe(prefix, path)
        if File.symlink?(path)
          raise "unlink rollback conflict: #{path}" unless File.readlink(path) == target
          next
        end
        if File.directory?(path)
          # Cache extraction may have replaced an old directory symlink with
          # real directories. Remove only empty directories, never user files.
          directories = []
          Find.find(path) do |child|
            raise "unlink rollback conflict: #{child}" unless File.directory?(child) && !File.symlink?(child)
            directories << child
          end
          directories.reverse_each { |directory| Dir.rmdir(directory) }
        end
        raise "unlink rollback conflict: #{path}" if File.exist?(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.symlink(target, path)
      end
      File.unlink(journal)
    end
    exit 0
  end
  names = names.map { |name| name.split('/').last }.uniq
  unsupported if names.empty?
  raise 'invalid formula name' unless names.all? { |name| !%w[. ..].include?(name) && name.match?(/\A[a-zA-Z0-9@+_.-]+\z/) }
  selected_paths = nil
  if ENV['PHP_DARWIN_UNLINK_PATHS_FILE']
    selected_paths = {}
    File.readlines(ENV.fetch('PHP_DARWIN_UNLINK_PATHS_FILE'), chomp: true).each do |relative|
      raise 'invalid selected unlink path' unless relative.match?(%r{\A(?:bin|etc|include|lib|opt|sbin|share|var)/}) &&
        !relative.match?(%r{(?:\A|/)\.\.?(/|\z)|//|[\r\n\t]}) && !relative.end_with?('/')
      path = File.join(prefix, relative)
      until path == prefix
        selected_paths[path] = true
        path = File.dirname(path)
      end
    end
  end
  begin
    acquire = lambda { |name| acquire_lock(prefix, name, locks) }
    names.sort.each { |name| acquire.call(name) }
    plans = []
    additional_locks = []
    names.each do |name|
      record = File.join(prefix, 'var/homebrew/linked', name)
      parents_safe(prefix, record)
      unsupported unless File.symlink?(record)
      keg = resolved(record)
      unsupported unless keg.match?(%r{\A#{Regexp.escape(prefix)}/Cellar/#{Regexp.escape(name)}/[^/]+\z}) &&
        File.directory?(keg) && !File.symlink?(keg)
      parents_safe(prefix, keg)
      opt = File.join(prefix, 'opt', name)
      parents_safe(prefix, opt)
      unsupported if File.exist?(opt) && resolved(opt) != keg
      receipt = JSON.parse(File.read(File.join(keg, 'INSTALL_RECEIPT.json')))
      aliases = receipt['aliases'] || []
      unsupported unless aliases.is_a?(Array) && aliases.all? { |value| value.is_a?(String) && !%w[. ..].include?(value) && value.match?(/\A[a-zA-Z0-9@+_.-]+\z/) }
      # Homebrew removes unversioned aliases of this keg during unlink. Record
      # only direct, owned aliases; unusual layouts still use the native command.
      aliases.reject { |value| value.include?('@') }.each do |value|
        %w[opt var/homebrew/linked].each do |directory|
          alias_path = File.join(prefix, directory, value)
          next unless File.exist?(alias_path) || File.symlink?(alias_path)
          unsupported unless File.symlink?(alias_path)
          target = resolved(alias_path)
          # A link to another installed keg is left alone, as Homebrew does.
          next if File.exist?(alias_path) && File.realpath(alias_path) != keg
          unsupported unless target.match?(%r{\A#{Regexp.escape(prefix)}/Cellar/#{Regexp.escape(name)}/[^/]+\z})
          additional_locks << value
          plans << {'path' => alias_path.delete_prefix(prefix + '/'), 'target' => File.readlink(alias_path)}
        end
      end
      Dir.glob(opt + '@*').each do |alias_path|
        next if aliases.include?(File.basename(alias_path))
        unsupported unless File.symlink?(alias_path)
        target = resolved(alias_path)
        if !File.exist?(alias_path)
          # php@8.5-debug can be a stale alias of the independent php-debug
          # rack. It must not force native unlinking of the active php rack.
          unsupported unless target.match?(%r{\A#{Regexp.escape(prefix)}/Cellar/[^/]+/[^/]+\z})
          unsupported if File.dirname(target) == File.dirname(keg)
        else
          unsupported if File.dirname(File.realpath(alias_path)) == File.dirname(keg)
        end
      end
      tap = receipt.dig('source', 'tap')
      if tap.is_a?(String)
        old_tap_opt = File.join(prefix, 'opt', tap.split('/').first)
        unsupported if File.directory?(old_tap_opt) && !File.symlink?(old_tap_opt)
      end
      Dir.glob(File.join(prefix, 'opt', '*')).each do |alias_path|
        next unless File.symlink?(alias_path) && File.directory?(alias_path)
        if File.dirname(resolved(alias_path)) == File.dirname(keg)
          additional_locks << File.basename(alias_path)
        end
      end
      %w[bin etc include lib sbin share var].each do |directory|
        root = File.join(keg, directory)
        next unless File.exist?(root)
        Find.find(root) do |source|
          destination = File.join(prefix, source.delete_prefix(keg + '/'))
          # Dependency upgrades only replace paths supplied by this archive.
          # Keep old documentation and other links to the preserved old keg.
          if selected_paths && !selected_paths.key?(destination)
            Find.prune
          end
          if File.symlink?(destination)
            if resolved(destination) == source
              unsupported if destination.match?(%r{info/(?:[^.].*?\.info(?:\.gz)?|dir)\z})
              plans << {'path' => destination.delete_prefix(prefix + '/'), 'target' => File.readlink(destination)}
              Find.prune if File.directory?(source)
            elsif File.directory?(source)
              unsupported
            end
          elsif !File.directory?(destination) && File.directory?(source)
            Find.prune
          end
        end
      end
      plans << {'path' => record.delete_prefix(prefix + '/'), 'target' => File.readlink(record)}
    end
    (additional_locks.uniq - names).sort.each { |name| acquire.call(name) }
    plans.uniq!
    plans.each do |entry|
      path = File.join(prefix, entry['path'])
      parents_safe(prefix, path)
      raise "Homebrew link changed: #{path}" unless File.symlink?(path) && File.readlink(path) == entry['target']
    end
    FileUtils.mkdir_p(journal_dir, mode: 0700)
    stamp = format('%020d-%d', Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond), Process.pid)
    Tempfile.create(['unlink-', '.tmp'], journal_dir) do |file|
      file.write(JSON.generate(plans))
      file.flush
      file.fsync
      File.rename(file.path, File.join(journal_dir, stamp + '.json'))
    end
    plans.each { |entry| File.unlink(File.join(prefix, entry['path'])) }
  end
rescue SystemCallError, JSON::ParserError, RuntimeError, ArgumentError, TypeError, KeyError => error
  warn "php-darwin: Homebrew links: #{error.message}"
  exit 1
ensure
  locks.reverse_each(&:close)
end
PHP_DARWIN_UNLINK_RUBY
