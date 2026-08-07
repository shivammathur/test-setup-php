# frozen_string_literal: true

formula = ARGV.fetch(0)
contents = File.read(formula)
needle = "  def install\n"

abort "Expected exactly one install method in #{formula}" unless contents.scan(needle).length == 1
abort "Formula already contains -mno-outline" if contents.include?("-mno-outline")
abort "Formula already contains -fno-split-cold-code" if contents.include?("-fno-split-cold-code")

flags = <<RUBY
  def install
    ENV.append "CFLAGS", "-mno-outline"
    ENV.append "CFLAGS", "-Xclang -fno-split-cold-code"
RUBY

File.write(formula, contents.sub(needle, flags))
