# Patch the producer's extension tap to use the exact restored PHP formula.
# Homebrew's formula_opt_bin constructs a path without resolving aliases.
file, formula, config_id, version = ARGV
abort 'Invalid PHP extension build context' unless
  formula&.match?(/\Aphp(?:@\d+\.\d+)?(?:-debug)?(?:-zts)?\z/) &&
  config_id&.match?(/\A\d+\.\d+(?:-debug)?(?:-zts)?\z/) &&
  version&.match?(/\A\d+\.\d+\z/)

source = File.read(file)
{
  'php@#{php_version}"' => "#{formula}\"",
  'php@#{@php_version}"' => "#{formula}\"",
  'etc / "php" / php_version / "conf.d"' => "etc / \"php\" / \"#{config_id}\" / \"conf.d\"",
}.each do |before, after|
  abort "Missing extension formula template: #{before}" unless source.scan(before).length == 1
  source = source.sub(before, after)
end
if version.start_with?('5.', '7.') && !source.include?('ENV["ac_cv_prog_cc_c23"] = "no"')
  abort 'Missing safe_phpize method' unless source.match?(/^\s*def safe_phpize$/)
  source = source.sub(/^(\s*)def safe_phpize$/, "\\1def safe_phpize\n\\1  ENV[\"ac_cv_prog_cc_c23\"] = \"no\"")
end
File.write(file, source)
