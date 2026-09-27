# Run inside Homebrew's existing Ruby process. `brew ruby` starts a second
# process after global.rb has consumed the ARM/Linux default-prefix variables,
# which can make compatible bottles appear to require the invalid /Cellar.
case ARGV.shift
when "info"
  require_relative "source-bottle-info"
when "prune"
  require_relative "source-bottle-prune"
when "install"
  require_relative "source-bottle-install"
when "select"
  require "formulary"
  require "keg"
  formula = Formulary.factory(ARGV.fetch(0))
  raise "Current keg is not installed" unless formula.latest_version_installed?
  Keg.new(formula.latest_installed_prefix).optlink(verbose: true)
else
  raise "Invalid source bottle command"
end
