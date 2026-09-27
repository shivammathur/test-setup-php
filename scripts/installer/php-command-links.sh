#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

php_darwin_ruby - "$@" <<'PHP_DARWIN_COMMAND_LINKS_RUBY'
require 'json'
require 'fileutils'

begin
  mode, prefix, journal, links_file, formula = ARGV
  commands = %w[bin/php bin/php-config bin/phpize sbin/php-fpm]
  raise 'unsafe Homebrew command directory' if %w[bin sbin].any? { |name| File.symlink?(File.join(prefix, name)) }
  case mode
  when 'prepare'
    entries = File.readlines(links_file, chomp: true).map do |line|
      relative, target = line.split("\t", -1)
      next unless commands.include?(relative)
      expected = File.expand_path(target, File.dirname(File.join(prefix, relative)))
      raise 'invalid archived PHP command' unless expected.start_with?(File.join(prefix, 'Cellar', formula) + '/')
      destination = File.join(prefix, relative)
      next unless File.exist?(destination) || File.symlink?(destination)
      raise "PHP command conflicts with an unmanaged file: #{destination}" unless File.symlink?(destination)
      previous = File.readlink(destination)
      resolved = File.expand_path(previous, File.dirname(destination))
      raise "PHP command conflicts with an unmanaged link: #{destination}" unless
        resolved.match?(%r{\A#{Regexp.escape(prefix)}/(?:Cellar|opt)/php(?:@[0-9.]+)?(?:-debug)?(?:-zts)?/})
      {'path' => relative, 'previous' => previous, 'installed' => target}
    end
    entries.compact!
    # Persist the complete plan before removing any link. Extraction supplies
    # the new default; this helper never discovers the version by running PHP.
    File.open(journal, 'w', 0600) { |file| file.write(JSON.generate(entries)); file.flush; file.fsync }
    entries.each { |entry| File.unlink(File.join(prefix, entry.fetch('path'))) }
  when 'restore'
    exit 0 unless File.file?(journal)
    JSON.parse(File.read(journal)).reverse_each do |entry|
      relative, previous, installed = entry.values_at('path', 'previous', 'installed')
      raise 'invalid command link journal' unless commands.include?(relative) && previous.is_a?(String) && installed.is_a?(String)
      destination = File.join(prefix, relative)
      if File.symlink?(destination)
        target = File.readlink(destination)
        next if target == previous
        raise "PHP command rollback conflict: #{destination}" unless target == installed
        File.unlink(destination)
      end
      raise "PHP command rollback conflict: #{destination}" if File.exist?(destination)
      FileUtils.mkdir_p(File.dirname(destination))
      File.symlink(previous, destination)
    end
    File.unlink(journal)
  else
    raise 'invalid PHP command link operation'
  end
rescue SystemCallError, JSON::ParserError, RuntimeError, ArgumentError, TypeError => error
  warn "php-darwin: #{error.message}"
  exit 1
end
PHP_DARWIN_COMMAND_LINKS_RUBY
