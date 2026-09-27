# Invoked as a Homebrew external command so resolution and bottle selection
# retain Homebrew's initialized platform defaults.
require "formulary"
require "formula_installer"
require "json"

Formulary.enable_factory_cache!
mode = ARGV.fetch(0)
formulae = JSON.parse(ARGV.fetch(1))
force_source = ARGV[2] == "true"
raise "Invalid source bottle mode" unless %w[plan seed inputs archive].include?(mode)

def current_installation?(formula)
  # Homebrew requires the current formula version, even if an older keg is
  # still installed. Match Dependency#installed? before skipping an update.
  formula.latest_version_installed? && missing_build_files(formula).empty?
end

def missing_build_files(formula)
  return [] unless formula.latest_version_installed? && formula.name.match?(/\Aicu4c(?:@[0-9]+)?\z/)

  # Hosted images can retain the current ICU receipt while omitting its
  # development files. Homebrew then omits ICU from PKG_CONFIG_PATH. Restore
  # that exact bottle only when the files needed by PHP configure are absent.
  %w[lib/pkgconfig/icu-uc.pc lib/pkgconfig/icu-i18n.pc include/unicode/utypes.h]
    .reject { |relative| (formula.latest_installed_prefix/relative).file? }
end

def source_dependencies(formula, planning:, force_source: false, runtime_only: false, ignore_installed: false)
  Dependency.expand(formula) do |dependent, dep|
    next Dependable::PRUNE if dep.optional? || (dep.test? && !dep.build?) ||
                             (dep.uses_from_macos? && dep.use_macos_install?)

    if dep.build?
      next Dependable::PRUNE if runtime_only
      building = if planning
        (ignore_installed || !current_installation?(dependent)) &&
          ((dependent == formula && force_source) || !FormulaInstaller.new(dependent).pour_bottle?)
      else
        # Inputs describe a source build of this formula. Its dependencies are
        # already installed: their runtime requirements matter, their original
        # build tools do not. Keep dependencies tagged both :build and :test.
        dependent == formula
      end
      next Dependable::PRUNE unless building
      # An installed build tool (notably the PHP archive used by extensions)
      # already runs with its installed libraries. Updating that tool's entire
      # runtime graph here can rebuild curl/OpenSSL for an unrelated extension.
      # Keep the tool itself, while direct extension runtime dependencies still
      # follow the normal version checks below.
      if planning && !ignore_installed && current_installation?(dep.to_formula)
        next Dependable::KEEP_BUT_PRUNE_RECURSIVE_DEPS
      end
    end
  end
end

def installed_inputs(dependency)
  keg = dependency.any_installed_keg
  raise "Missing build dependency #{dependency.full_name}" unless keg

  tab = Tab.for_keg(keg)
  recipe = keg/".brew/#{dependency.name}.rb"
  raise "Missing installed dependency recipe #{recipe}" unless recipe.file?

  { name: dependency.full_name, version: keg.version.to_s, recipe: recipe.to_s,
    options: tab.used_options.as_flags.sort, compiler: tab.compiler.to_s,
    runtime_dependencies: tab.runtime_dependencies }
end

resolved = formulae.map { |name| Formulary.factory(name) }
requested_names = resolved.map(&:full_name)
if %w[plan seed].include?(mode)
  resolved = resolved.flat_map do |formula|
    source_dependencies(formula, planning: true, force_source:, ignore_installed: mode == "seed")
      .map(&:to_formula) + [formula]
  end.uniq(&:full_name)
end

records = resolved.map do |formula|
  installer = FormulaInstaller.new(formula)
  record = {
    name: formula.name,
    full_name: formula.full_name,
    requested: requested_names.include?(formula.full_name),
    version: formula.pkg_version.to_s,
    prefix: formula.prefix.to_s,
    recipe: formula.path.to_s,
    installed: current_installation?(formula),
    installed_versions: formula.installed_kegs.map { |keg| keg.version.to_s },
    missing_build_files: missing_build_files(formula),
    select_current: current_installation?(formula) &&
      (!formula.opt_prefix.exist? || formula.opt_prefix.realpath != formula.latest_installed_prefix.realpath),
    bottled: installer.pour_bottle?,
    post_install: formula.post_install_defined? || formula.post_install_steps_defined?,
  }
  if mode == "plan"
    # Only configuration files recorded in this formula's installed bottles
    # belong to its source-build transaction. Never stage service data in var.
    record[:configuration_files] = formula.installed_kegs.flat_map do |keg|
      root = keg/".bottle"
      (root/"etc").glob("**/*", File::FNM_DOTMATCH)
        .select { |file| file.file? || file.symlink? }
        .map { |file| file.relative_path_from(root).to_s }
    end.uniq.sort
  end
  if %w[plan seed].include?(mode) && record[:bottled]
    # Older hosted Homebrew versions select directly from the formula. Newer
    # versions can also select an internal-API bottle through the installer.
    bottle = installer.respond_to?(:selected_bottle) ? installer.selected_bottle : formula.bottle
    record[:bottle] = {
      formula: formula.full_name, version: formula.pkg_version.to_s, tag: bottle.tag.to_s,
      sha256: bottle.resource.checksum.hexdigest, url: bottle.url,
      cached_download: bottle.cached_download.to_s,
    }
  end
  if mode == "archive"
    record[:packages] = (source_dependencies(formula, planning: false, runtime_only: true)
      .map(&:to_formula) + [formula]).uniq(&:full_name).map do |dependency|
        installed_inputs(dependency).merge(prefix: dependency.any_installed_keg.to_s)
      end
      .sort_by { |dependency| dependency[:name] }
  elsif mode == "inputs"
    record[:dependencies] = source_dependencies(formula, planning: false).map do |dep|
      installed_inputs(dep.to_formula)
    end.sort_by { |dep| dep[:name] }
  end
  record
end
puts JSON.generate(records)
