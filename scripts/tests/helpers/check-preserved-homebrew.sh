#!/usr/bin/env bash
# Compatibility-test evidence only; never called by the package installer.
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../../lib/lib.sh"
php_darwin_ruby - "$@" <<'RUBY'
require 'json'
require 'digest'
mode, prefix, state_file, *service_directories = ARGV
raise 'Invalid preservation check' unless %w[snapshot check].include?(mode)
def php_version(keg)
  output = IO.popen([File.join(keg, 'bin', 'php-config'), '--version'], err: File::NULL, &:read)
  return nil unless $?.success?
  # Runtime preservation is a loader smoke test; version discovery uses php-config.
  works = system(File.join(keg, 'bin', 'php'), '-n', '-r', 'exit(0);', out: File::NULL, err: File::NULL)
  works ? output.strip : nil
rescue SystemCallError
  nil
end
kegs = Dir.glob(File.join(prefix, 'Cellar', 'php*', '*')).select do |keg|
  File.basename(File.dirname(keg)).match?(/\Aphp(@[0-9]+\.[0-9]+)?(-debug)?(-zts)?\z/) &&
    File.directory?(keg) && File.executable?(File.join(keg, 'bin', 'php'))
end.sort
services = service_directories.flat_map { |directory| Dir.glob(File.join(directory, '*php*.plist')) }.sort.to_h do |file|
  [file, { 'target' => File.symlink?(file) ? File.readlink(file) : nil,
           'sha256' => File.file?(file) ? Digest::SHA256.file(file).hexdigest : nil }]
end
if mode == 'snapshot'
  runtimes = kegs.to_h { |keg| [keg, php_version(keg)] }.reject { |_, version| version.nil? }
  File.write(state_file, JSON.generate({ 'kegs' => kegs, 'runtimes' => runtimes, 'services' => services }))
else
  before = JSON.parse(File.read(state_file))
  missing = before.fetch('kegs') - kegs
  raise "Removed existing PHP kegs: #{missing.join(', ')}" unless missing.empty?
  raise 'PHP service definitions changed' unless before.fetch('services') == services
  before.fetch('runtimes', {}).each do |keg, version|
    raise "Existing PHP runtime changed or stopped working: #{keg}" unless php_version(keg) == version
  end
  puts "Preserved #{before.fetch('kegs').length} existing PHP kegs and #{services.length} PHP service definitions"
  puts "Verified #{before.fetch('runtimes', {}).length} existing PHP runtimes still execute with the same version"
end
RUBY
