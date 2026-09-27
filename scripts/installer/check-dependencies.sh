#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

php_darwin_ruby - "$@" <<'PHP_DARWIN_DEPENDENCIES_RUBY'
require 'json'
begin
  prefix, packages = ARGV
  dependencies = []
  File.foreach(packages) do |line|
    name, target, keg_only, extra = line.strip.split("\t")
    raise 'invalid package receipt path' unless extra.nil? && %w[true false].include?(keg_only) &&
      name.match?(/\A[a-zA-Z0-9@+_.-]+\z/) && target.match?(%r{\A\.\./Cellar/#{Regexp.escape(name)}/[^/\s]+\z})
    receipt = File.join(prefix, target.delete_prefix('../'), 'INSTALL_RECEIPT.json')
    exit 78 unless File.file?(receipt)
    data = JSON.parse(File.read(receipt))
    entries = data['runtime_dependencies']
    exit 78 unless entries.is_a?(Array)
    entries.each do |entry|
      exit 78 unless entry.is_a?(Hash) && entry['full_name'].is_a?(String)
      dependency = entry['full_name'].split('/').last
      raise 'invalid runtime dependency name' unless dependency && !%w[. ..].include?(dependency) && dependency.match?(/\A[a-zA-Z0-9@+_.-]+\z/)
      dependencies << dependency
    end
  end
  # Homebrew's missing_dependencies uses installed receipt data, not current
  # formula definitions. Check every cached package, including transitive deps.
  missing = dependencies.uniq.sort.reject do |name|
    File.directory?(File.join(prefix, 'Cellar', name)) || File.directory?(File.join(prefix, 'opt', name))
  end
  unless missing.empty?
    puts missing.join(' ')
    exit 1
  end
rescue SystemCallError, JSON::ParserError, RuntimeError, ArgumentError => error
  warn "php-darwin: dependency receipts: #{error.message}"
  exit 1
end
PHP_DARWIN_DEPENDENCIES_RUBY
