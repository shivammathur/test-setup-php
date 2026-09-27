# The JS planner has already installed every required dependency. Skip further
# installation, but keep Homebrew's normal dependency-aware compiler environment:
# passing --ignore-dependencies into build.rb would strip PHP's header paths and
# omit keg-only library/tool paths. This override lives only in this brew process.
require "formula_installer"
require "cmd/install"

raise "Expected an explicitly planned source build" unless
  ARGV.include?("--ignore-dependencies") && ARGV.include?("--build-bottle")

module PhpDarwinSourceBuildEnvironment
  def sanitized_argv_options
    super.reject { |option| option == "--ignore-dependencies" }
  end
end
FormulaInstaller.prepend(PhpDarwinSourceBuildEnvironment)
installation = Homebrew::Cmd::InstallCmd.new(ARGV)
Context.current = installation.args.context
installation.run
