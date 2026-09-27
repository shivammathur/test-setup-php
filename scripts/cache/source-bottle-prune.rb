require "pkg_version"
require "json"

versions = JSON.parse(ARGV.fetch(0))
newest = versions.map { |version| PkgVersion.parse(version) }.max
puts JSON.generate(versions.select { |version| PkgVersion.parse(version) < newest }.uniq)
