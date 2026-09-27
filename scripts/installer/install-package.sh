#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

PHP_DARWIN_PHASE=input
version=${1:-}
build=${2:-release}
ts=${3:-nts}
local_archive=${4:-}
# setup-php exports its action input to child processes. Older action revisions
# call this installer with three arguments; use that input on the cold path too.
extensions_input=${5-${PHP_DARWIN_EXTENSIONS:-${INPUT_EXTENSIONS:-}}}
arch=$(php_darwin_normalize_arch "$(uname -m)") || exit 1

PHP_DARWIN_PHASE=environment
[ "$(uname -s)" = Darwin ] || php_darwin_die 'the cache installer only supports macOS'
for required_command in brew curl jq tar zstd; do
  command -v "$required_command" >/dev/null 2>&1 || php_darwin_die "$required_command is required"
done

install_config=$(jq -ers --arg arch "$arch" '
  def install_string: type == "string" and length > 0 and test("^[^\\r\\n\\t]+$");
  .[0] as $package | .[1][$arch] as $platform |
  select(($package.current_version | install_string) and
    ($package.release_repository | install_string) and
    ($package.tap | install_string) and
    ($package.tap_repository | install_string) and
    ($package.tap_branch | install_string) and
    ($package.tap_snapshot | install_string) and
    ($platform.brew_prefix | install_string) and
    ($platform.minimum_macos | type == "number" and floor == . and . > 0) and
    ($platform.platform_key | install_string)) |
  [$package.current_version, $package.release_repository, $package.tap,
   $package.tap_repository, $package.tap_branch, $package.tap_snapshot,
   $platform.brew_prefix, ($platform.minimum_macos | tostring), $platform.platform_key] | @tsv
' < <(php_darwin_read_config package.json; php_darwin_read_config platforms.json)) || \
  php_darwin_die 'could not read the package and platform configuration'
IFS=$'\t' read -r current_version package_release_repository tap tap_repository tap_branch \
  tap_snapshot expected_prefix minimum_macos platform_key install_config_extra <<< "$install_config" || \
  php_darwin_die 'could not parse the package and platform configuration'
[ -z "$install_config_extra" ] && [ -n "$platform_key" ] || \
  php_darwin_die 'package and platform configuration fields are invalid'
[ -n "$version" ] || version=$current_version
php_darwin_validate_version "$version"
channel=$(php_darwin_version_channel "$version") || exit 1
php_darwin_validate_build "$build"
php_darwin_validate_ts "$ts"
requested_formula=$(php_darwin_requested_formula "$version" "$build" "$ts") || exit 1
formula=$(php_darwin_formula "$version" "$build" "$ts" "$current_version") || exit 1
config_id=$(php_darwin_config_id "$version" "$build" "$ts") || exit 1
asset=$(php_darwin_asset "$version" "$build" "$ts" "$arch") || exit 1
pear_path=$(php_darwin_pear_path "$version" "$formula") || exit 1
internal_metadata_path=$(php_darwin_metadata_path "$asset") || exit 1

brew_command=$(command -v brew)
if [ "$brew_command" = "$expected_prefix/bin/brew" ]; then
  brew_prefix=$expected_prefix
else
  brew_prefix=$(brew --prefix) || php_darwin_die 'could not determine the Homebrew prefix'
fi
[ "$brew_prefix" = "$expected_prefix" ] || php_darwin_die "architecture $arch requires Homebrew at $expected_prefix, found $brew_prefix"
internal_metadata_dir="$brew_prefix/${internal_metadata_path%/*}"
macos_version=$(sw_vers -productVersion) || php_darwin_die 'could not determine the macOS version'
macos_major=${macos_version%%.*}
case "$tap_snapshot" in var/php-darwin/*) ;; *)
  php_darwin_die "unsafe Homebrew tap snapshot path: $tap_snapshot"
  ;;
esac
case "$tap_snapshot" in *$'\n'*|*$'\r'*|*$'\t'*|*'/../'*|../*|*/..|*'//'* )
  php_darwin_die "unsafe Homebrew tap snapshot path: $tap_snapshot"
  ;;
esac

[ ! -L "$internal_metadata_dir" ] || php_darwin_die 'embedded metadata directory is a symlink'
[ ! -e "$internal_metadata_dir" ] || [ -d "$internal_metadata_dir" ] || \
  php_darwin_die 'embedded metadata path is not a directory'
mkdir -p "$internal_metadata_dir" || php_darwin_die 'could not create the embedded metadata directory'

while IFS= read -r managed_dir extra; do
  [ -n "$managed_dir" ] || continue
  case "$managed_dir" in \#*) continue ;; esac
  [ -z "$extra" ] || php_darwin_die "invalid archive root: $managed_dir $extra"
  case "$managed_dir" in Cellar|Frameworks|bin|etc|include|lib|opt|sbin|share|var) ;; *)
    php_darwin_die "unsafe archive root: $managed_dir"
    ;;
  esac
  [ ! -L "$brew_prefix/$managed_dir" ] || \
    php_darwin_die "Homebrew directory is a symlink: $brew_prefix/$managed_dir"
  [ -d "$brew_prefix/$managed_dir" ] || mkdir -p "$brew_prefix/$managed_dir" || \
    php_darwin_die "could not create Homebrew directory: $brew_prefix/$managed_dir"
  [ -w "$brew_prefix/$managed_dir" ] || \
    php_darwin_die "Homebrew directory is not writable: $brew_prefix/$managed_dir"
done < <(php_darwin_read_config archive-paths)

php_darwin_configure_homebrew_environment

tmp_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-install.XXXXXX") || \
  php_darwin_die 'could not create the installation directory'
php_darwin_select_ruby
archive_roots_file="$tmp_dir/archive-paths.txt"
php_darwin_read_config archive-paths > "$archive_roots_file" || \
  php_darwin_die 'could not stage the archive root configuration'
tap_log="$tmp_dir/homebrew-tap.log"
tap_pid=
tap_action_file="$tmp_dir/homebrew-tap-action.txt"
homebrew_prepare_log="$tmp_dir/homebrew-prepare.log"
homebrew_prepare_pid=
homebrew_trust_pid=
homebrew_trust_log="$tmp_dir/homebrew-trust.log"
homebrew_prepare_phase_file="$tmp_dir/homebrew-prepare-phase.txt"
php_unlink_mode_file="$tmp_dir/php-unlink-mode"
dependency_unlink_mode_file="$tmp_dir/dependency-unlink-mode"
unlink_journal_dir="$tmp_dir/unlinked"
command_links_journal="$tmp_dir/php-command-links.json"
tap_path_file="$tmp_dir/homebrew-tap-path.txt"
tap_trust_file="$tmp_dir/homebrew-tap-trust.txt"
initial_formula_trust_file="$tmp_dir/homebrew-formula-trust.txt"
missing_log="$tmp_dir/homebrew-missing.log"
missing_pid=
missing_status=
missing_output=
archive_hash_file="$tmp_dir/archive.sha256"
archive_hash_log="$tmp_dir/archive-hash.log"
archive_hash_pid=
linked_php_references=()
linked_dependency_references=()
postinstall_paths_file="$tmp_dir/postinstall-paths.txt"
postinstall_candidates_file="$tmp_dir/postinstall-candidates.txt"
postinstall_backup_dir="$tmp_dir/postinstall-backup"
postinstall_restored_file="$tmp_dir/postinstall-restored.txt"
pear_backup="$tmp_dir/pear-backup"
pear_backed_up=false
pear_restored=false
previous_opt_links="$tmp_dir/previous-opt-links.tsv"
new_state_paths_file="$tmp_dir/new-state-paths.txt"
target_keg_backup="$tmp_dir/target-keg-backup"
target_keg_backed_up=false
formula_trust_marker="$tmp_dir/formula-trust-added"
formula_trust_pending="$tmp_dir/formula-trust-pending"
tap_was_trusted=false
tap_installed=false
tap_path=
tap_path_backup=
tap_path_backed_up=false
tap_snapshot_backup="$tmp_dir/homebrew-tap-snapshot-backup"
tap_snapshot_backed_up=false
tap_snapshot_extracted=false
tap_replaced=false
tap_restore_after_install=false
dependencies_started_with_pending_tap=false
tap_snapshot_path="$brew_prefix/$tap_snapshot"
: > "$previous_opt_links" || php_darwin_die 'could not create the Homebrew opt-link backup'
: > "$postinstall_restored_file" || php_darwin_die 'could not create the restored-state list'
: > "$new_state_paths_file" || php_darwin_die 'could not create the new-state list'
archive_mutation_started=false
runtime_verified=false
extension_prefetch_pid=
extension_node=
extension_dir="$tmp_dir/extensions"
preserve_tmp_dir=false
php_darwin_unlink_formulae() {
  local mode_file=$1
  local unlink_status=0
  shift

  printf 'fast\n' > "$mode_file" || return 1
  bash "$script_dir/unlink-kegs.sh" unlink "$brew_prefix" "$unlink_journal_dir" "$@" || unlink_status=$?
  if [ "$unlink_status" -eq 78 ]; then
    printf 'brew\n' > "$mode_file" || return 1
    brew unlink "$@"
  else
    return "$unlink_status"
  fi
}

php_darwin_check_installed_dependencies() {
  local dependency_status=0

  bash "$script_dir/check-dependencies.sh" "$brew_prefix" "$packages_file" || dependency_status=$?
  if [ "$dependency_status" -eq 78 ]; then
    brew missing "$tap/$formula"
  else
    return "$dependency_status"
  fi
}

php_darwin_collect_dependencies() {
  [ -n "$missing_pid" ] || return 0
  if wait "$missing_pid"; then
    missing_status=0
  else
    missing_status=$?
  fi
  missing_pid=
  missing_output=$(cat "$missing_log") || php_darwin_die 'could not read Homebrew dependency diagnostics'
}

php_darwin_validate_dependencies() {
  [ -n "$missing_status" ] || return 0
  [ "$missing_status" -eq 0 ] || [ -n "$missing_output" ] || \
    php_darwin_die 'Homebrew dependency validation failed without diagnostics'
  if [ -n "$missing_output" ]; then
    php_darwin_die "cache has missing Homebrew dependencies: $missing_output"
  fi
  missing_status=
  missing_output=
}

php_darwin_wait_for_dependencies() {
  php_darwin_collect_dependencies
  php_darwin_validate_dependencies
}

php_darwin_resolve_tap_and_dependencies() {
  if [ -n "$tap_pid" ]; then
    # Do not replace the tap while Homebrew is reading the outgoing formula.
    # Its result is authoritative only if that tap remains installed.
    php_darwin_collect_dependencies
    php_darwin_wait_for_tap
    if [ "$tap_replaced" = true ] && [ "$dependencies_started_with_pending_tap" = true ]; then
      missing_status=
      missing_output=
      PHP_DARWIN_PHASE=homebrew.dependencies
      php_darwin_check_installed_dependencies > "$missing_log" 2>&1 &
      missing_pid=$!
    fi
  else
    php_darwin_wait_for_tap
  fi
  PHP_DARWIN_PHASE=homebrew.dependencies
  php_darwin_wait_for_dependencies
}

php_darwin_wait_for_tap() {
  local tap_action
  local tap_status

  [ -n "$tap_pid" ] || return 0
  if wait "$tap_pid"; then
    tap_status=0
  else
    tap_status=$?
  fi
  tap_pid=
  if [ "$tap_status" -ne 0 ]; then
    PHP_DARWIN_PHASE=homebrew.tap
    cat "$tap_log" >&2
    php_darwin_die "could not validate $tap"
  fi
  PHP_DARWIN_PHASE=homebrew.tap
  tap_action=$(cat "$tap_action_file") || php_darwin_die "could not read the $tap tap action"
  case "$tap_action" in
    keep)
      find "$tap_snapshot_path" -mindepth 1 -delete || \
        php_darwin_die 'could not remove the unused Homebrew tap snapshot'
      rmdir "$tap_snapshot_path" || php_darwin_die 'could not remove the empty Homebrew tap snapshot'
      tap_snapshot_extracted=false
      ;;
    replace|temporary)
      [ "$tap_action" != temporary ] || tap_restore_after_install=true
      tap_path_backed_up=true
      if ! mv "$tap_path" "$tap_path_backup" 2>/dev/null; then
        command -v sudo >/dev/null 2>&1 || \
          php_darwin_die "could not back up the older $tap snapshot"
        sudo -n mv "$tap_path" "$tap_path_backup" || \
          php_darwin_die "could not back up the older $tap snapshot"
      fi
      tap_installed=true
      if ! mv "$tap_snapshot_path" "$tap_path" 2>/dev/null; then
        command -v sudo >/dev/null 2>&1 || \
          php_darwin_die "could not install the cached $tap snapshot"
        sudo -n mv "$tap_snapshot_path" "$tap_path" || \
          php_darwin_die "could not install the cached $tap snapshot"
      fi
      tap_snapshot_extracted=false
      tap_replaced=true
      ;;
    *) php_darwin_die "invalid $tap tap action: $tap_action" ;;
  esac
}

php_darwin_wait_for_homebrew_prepare() {
  local failed_phase
  local prepare_status

  [ -n "$homebrew_prepare_pid" ] || return 0
  if wait "$homebrew_prepare_pid"; then
    prepare_status=0
  else
    prepare_status=$?
  fi
  homebrew_prepare_pid=
  if [ "$prepare_status" -ne 0 ]; then
    failed_phase=$(cat "$homebrew_prepare_phase_file" 2>/dev/null) || \
      failed_phase=homebrew.prepare
    case "$failed_phase" in
      homebrew.trust-state|homebrew.tap-path|homebrew.unlink) ;;
      *) failed_phase=homebrew.prepare ;;
    esac
    PHP_DARWIN_PHASE="$failed_phase"
    cat "$homebrew_prepare_log" >&2
    case "$failed_phase" in
      homebrew.trust-state) php_darwin_die "could not read the $tap trust state" ;;
      homebrew.tap-path) php_darwin_die "could not resolve the $tap repository path" ;;
      homebrew.unlink) php_darwin_die 'could not unlink the active Homebrew PHP formulae' ;;
      *) php_darwin_die 'could not prepare Homebrew for cache installation' ;;
    esac
  fi
  if ! wait "$homebrew_trust_pid"; then
    homebrew_trust_pid=
    PHP_DARWIN_PHASE=homebrew.trust-state
    cat "$homebrew_trust_log" >&2
    php_darwin_die "could not read the $tap trust state"
  fi
  homebrew_trust_pid=
  tap_path=$(cat "$tap_path_file") || php_darwin_die "could not read the $tap repository path"
  tap_was_trusted=$(cat "$tap_trust_file") || \
    php_darwin_die "could not read the $tap trust state"
  case "$tap_was_trusted" in true|false) ;; *) php_darwin_die "invalid $tap trust state" ;; esac
}

php_darwin_start_archive_hash() {
  local archive_to_hash=$1

  (
    php_darwin_sha256 "$archive_to_hash" > "$archive_hash_file"
  ) > "$archive_hash_log" 2>&1 &
  archive_hash_pid=$!
}

php_darwin_wait_for_archive_hash() {
  local hash_status

  [ -n "$archive_hash_pid" ] || return 0
  if wait "$archive_hash_pid"; then
    hash_status=0
  else
    hash_status=$?
  fi
  archive_hash_pid=
  if [ "$hash_status" -ne 0 ]; then
    cat "$archive_hash_log" >&2
    php_darwin_die "could not hash $asset"
  fi
  actual_hash=$(cat "$archive_hash_file") || php_darwin_die "could not read the $asset hash"
}

php_darwin_restore_formula_trust() {
  local added_formula
  local added_formulae=()
  local trust_entries_file
  local trust_restore_status

  [ -f "$formula_trust_marker" ] || [ -f "$formula_trust_pending" ] || return 0
  trust_entries_file=$formula_trust_marker
  [ -f "$trust_entries_file" ] || trust_entries_file=$formula_trust_pending
  while IFS= read -r added_formula; do
    case "$added_formula" in "$tap/"*) added_formulae+=("$added_formula") ;; *) return 1 ;; esac
  done < "$trust_entries_file"
  if [ "${#added_formulae[@]}" -eq 0 ]; then
    rm -f "$formula_trust_marker" "$formula_trust_pending"
    return 0
  fi
  # Homebrew's untrust command is idempotent. The marker contains only
  # formulae absent from the initial trust snapshot, so querying trust again
  # after archive extraction is unnecessary and would depend on the mutated
  # Homebrew prefix during rollback.
  trust_restore_status=0
  bash "$script_dir/trust-store.sh" remove "$brew_prefix" "$tap" '' "${added_formulae[@]}" || trust_restore_status=$?
  if [ "$trust_restore_status" -eq 78 ]; then
    trust_restore_status=0
    brew untrust --formula "${added_formulae[@]}" || trust_restore_status=$?
  fi
  [ "$trust_restore_status" -eq 0 ] || {
    printf 'Run brew untrust --formula %s to remove trust added by the failed cache install\n' \
      "${added_formulae[*]}" >&2
    return 1
  }
  rm -f "$formula_trust_marker" "$formula_trust_pending"
}

php_darwin_install_cleanup() {
  cleanup_status=$?
  PHP_DARWIN_PHASE=cleanup
  rollback_status=ok
  rollback_attempted=false
  rollback_log="$tmp_dir/rollback.log"
  trap - EXIT
  trap '' HUP INT TERM
  : > "$rollback_log"
  # Give the potentially mutating Homebrew preparation a bounded opportunity
  # to finish. Read-only validation jobs can be stopped immediately.
  php_darwin_reap_job "$homebrew_prepare_pid" 20
  php_darwin_reap_job "$homebrew_trust_pid" 0
  php_darwin_reap_job "$tap_pid" 0
  php_darwin_reap_job "$missing_pid" 0
  php_darwin_reap_job "$archive_hash_pid" 0
  # The Node supervisor drains its read-only extraction children on termination.
  php_darwin_reap_job "$extension_prefetch_pid" 5
  if [ "$cleanup_status" -ne 0 ] && [ "$runtime_verified" = false ]; then
    rollback_attempted=true
    if [ "$tap_installed" = true ]; then
      if [ ! -e "$tap_path" ] && [ ! -L "$tap_path" ]; then
        :
      elif [ -d "$tap_path" ] && [ ! -L "$tap_path" ]; then
        php_darwin_remove_tap_path "$brew_prefix" "$tap_path" >> "$rollback_log" 2>&1 || \
          rollback_status=failed
      else
        rollback_status=failed
      fi
    fi
    if [ "$tap_path_backed_up" = true ]; then
      if [ ! -e "$tap_path_backup" ] && [ ! -L "$tap_path_backup" ] && \
        { [ -e "$tap_path" ] || [ -L "$tap_path" ]; }; then
        tap_path_backed_up=false
      elif php_darwin_restore_tap_path "$tap_path" "$tap_path_backup" >> "$rollback_log" 2>&1; then
        tap_path_backed_up=false
      else
        rollback_status=failed
      fi
    fi
    if [ "$tap_snapshot_extracted" = true ] && \
      { [ -e "$tap_snapshot_path" ] || [ -L "$tap_snapshot_path" ]; }; then
      if [ -d "$tap_snapshot_path" ] && [ ! -L "$tap_snapshot_path" ]; then
        find "$tap_snapshot_path" -mindepth 1 -delete >> "$rollback_log" 2>&1 && \
          rmdir "$tap_snapshot_path" >> "$rollback_log" 2>&1 || rollback_status=failed
      else
        rollback_status=failed
      fi
    fi
    if [ "$tap_snapshot_backed_up" = true ] && [ -d "$tap_snapshot_backup" ]; then
      mkdir -p "${tap_snapshot_path%/*}" >> "$rollback_log" 2>&1 && \
        mv "$tap_snapshot_backup" "$tap_snapshot_path" >> "$rollback_log" 2>&1 || rollback_status=failed
    fi
    if [ -s "${changed_formulae_file:-}" ]; then
      if [ -s "${installed_links_file:-}" ]; then
        while IFS=$'\t' read -r rollback_link rollback_target; do
          rollback_owned=false
          while IFS= read -r rollback_formula; do
            case "$rollback_target" in *"Cellar/$rollback_formula/"*) rollback_owned=true; break ;; esac
          done < "$changed_formulae_file"
          if [ "$rollback_owned" = true ] && [ -L "$brew_prefix/$rollback_link" ] && \
            [ "$(readlink "$brew_prefix/$rollback_link")" = "$rollback_target" ]; then
            rm -f "$brew_prefix/$rollback_link" >> "$rollback_log" 2>&1 || rollback_status=failed
          fi
        done < "$installed_links_file"
      fi
      if [ -s "${packages_file:-}" ]; then
        while IFS=$'\t' read -r rollback_formula rollback_opt_target rollback_keg_only; do
          case "$rollback_keg_only" in true|false) ;; *) rollback_status=failed; continue ;; esac
          grep -Fxq "$rollback_formula" "$changed_formulae_file" || continue
          rollback_opt="$brew_prefix/opt/$rollback_formula"
          if [ -L "$rollback_opt" ] && [ "$(readlink "$rollback_opt")" = "$rollback_opt_target" ]; then
            rm -f "$rollback_opt" >> "$rollback_log" 2>&1 || rollback_status=failed
          fi
          rollback_keg=${rollback_opt_target#../}
          case "$rollback_keg" in "Cellar/$rollback_formula/"*)
            rm -rf "${brew_prefix:?}/${rollback_keg:?}" >> "$rollback_log" 2>&1 || rollback_status=failed
            # Extraction may have created the rack. Remove it only when empty;
            # an older side-by-side keg keeps the directory in place.
            rmdir "$brew_prefix/Cellar/$rollback_formula" >> "$rollback_log" 2>&1 || true
            ;;
          esac
        done < "$packages_file"
      fi
      while IFS=$'\t' read -r rollback_formula rollback_opt_target; do
        rollback_opt="$brew_prefix/opt/$rollback_formula"
        if [ -e "$rollback_opt" ] && [ ! -L "$rollback_opt" ]; then
          rollback_status=failed
          continue
        fi
        if [ ! -L "$rollback_opt" ] || [ "$(readlink "$rollback_opt")" != "$rollback_opt_target" ]; then
          rm -f "$rollback_opt" >> "$rollback_log" 2>&1 && \
            ln -s "$rollback_opt_target" "$rollback_opt" >> "$rollback_log" 2>&1 || rollback_status=failed
        fi
      done < "$previous_opt_links"
    fi
    if [ "$target_keg_backed_up" = true ]; then
      if [ -e "$brew_prefix/$target_keg_relative" ] || [ -L "$brew_prefix/$target_keg_relative" ]; then
        rm -rf "${brew_prefix:?}/${target_keg_relative:?}" >> "$rollback_log" 2>&1 || \
          rollback_status=failed
      fi
      mkdir -p "$brew_prefix/${target_keg_relative%/*}" >> "$rollback_log" 2>&1 && \
        mv "$target_keg_backup" "$brew_prefix/$target_keg_relative" >> "$rollback_log" 2>&1 || \
        rollback_status=failed
      target_keg_backed_up=false
    fi
    if [ "$archive_mutation_started" = true ] && [ -s "$new_state_paths_file" ]; then
      while IFS= read -r rollback_state_path; do
        [ -n "$rollback_state_path" ] || continue
        rm -rf "${brew_prefix:?}/${rollback_state_path:?}" >> "$rollback_log" 2>&1 || \
          rollback_status=failed
      done < "$new_state_paths_file"
    fi
    if [ "$pear_backed_up" = true ]; then
      rm -rf "${brew_prefix:?}/${pear_path:?}" >> "$rollback_log" 2>&1 || rollback_status=failed
      mkdir -p "$brew_prefix/${pear_path%/*}" >> "$rollback_log" 2>&1 && \
        mv "$pear_backup" "$brew_prefix/$pear_path" >> "$rollback_log" 2>&1 || rollback_status=failed
      pear_backed_up=false
    elif [ "$archive_mutation_started" = true ] && [ "$pear_restored" = false ]; then
      rm -rf "${brew_prefix:?}/${pear_path:?}" >> "$rollback_log" 2>&1 || rollback_status=failed
    fi
    if [ -s "$postinstall_paths_file" ]; then
      while IFS= read -r postinstall_path; do
        [ -n "$postinstall_path" ] || continue
        if [ -e "$postinstall_backup_dir/$postinstall_path" ] || \
          [ -L "$postinstall_backup_dir/$postinstall_path" ]; then
          rm -rf "${brew_prefix:?}/${postinstall_path:?}" >> "$rollback_log" 2>&1 || rollback_status=failed
          mkdir -p "$brew_prefix/${postinstall_path%/*}" >> "$rollback_log" 2>&1 && \
            mv "$postinstall_backup_dir/$postinstall_path" "$brew_prefix/$postinstall_path" \
              >> "$rollback_log" 2>&1 || rollback_status=failed
        elif grep -Fxq "$postinstall_path" "$postinstall_restored_file"; then
          continue
        elif [ "$archive_mutation_started" = true ]; then
          rm -rf "${brew_prefix:?}/${postinstall_path:?}" >> "$rollback_log" 2>&1 || rollback_status=failed
        fi
      done < "$postinstall_paths_file"
    fi
    if [ "$archive_mutation_started" = true ]; then
      rm -f "$brew_prefix/$internal_metadata_path" >> "$rollback_log" 2>&1 || rollback_status=failed
    fi
    bash "$script_dir/php-command-links.sh" restore "$brew_prefix" "$command_links_journal" >> "$rollback_log" 2>&1 || \
      rollback_status=failed
    if [ -d "$unlink_journal_dir" ]; then
      bash "$script_dir/unlink-kegs.sh" restore "$brew_prefix" "$unlink_journal_dir" >> "$rollback_log" 2>&1 || \
        rollback_status=failed
    fi
    if [ "${#linked_php_references[@]}" -gt 0 ] && [ "$(cat "$php_unlink_mode_file" 2>/dev/null)" = brew ]; then
      brew link --overwrite --force "${linked_php_references[@]}" >> "$rollback_log" 2>&1 || \
        rollback_status=failed
    fi
    if [ "${#linked_dependency_references[@]}" -gt 0 ] && [ "$(cat "$dependency_unlink_mode_file" 2>/dev/null)" = brew ]; then
      brew link --overwrite "${linked_dependency_references[@]}" >> "$rollback_log" 2>&1 || \
        rollback_status=failed
    fi
    php_darwin_restore_formula_trust >> "$rollback_log" 2>&1 || rollback_status=failed
  fi
  if [ "$cleanup_status" -ne 0 ]; then
    if [ "$rollback_attempted" = false ]; then
      printf 'php-darwin: verified installation preserved after post-install interruption\n' >&2
    elif [ "$rollback_status" = failed ]; then
      printf 'php-darwin: rollback failed; Homebrew diagnostics follow\n' >&2
      cat "$rollback_log" >&2
    fi
    [ "$rollback_attempted" = false ] || printf 'php-darwin: rollback %s\n' "$rollback_status" >&2
  fi
  if [ "$runtime_verified" = true ] && [ "$tap_snapshot_backed_up" = true ]; then
    preserve_tmp_dir=true
    printf 'php-darwin: restore the previous cache tap with: sudo mv %s %s\n' \
      "$tap_snapshot_backup" "$tap_snapshot_path" >&2
  fi
  # A failed restore must never discard the only remaining copies of user
  # state. Keep the entire transaction, including journals and diagnostics.
  if [ "$rollback_status" = failed ]; then
    preserve_tmp_dir=true
  fi
  if [ "$preserve_tmp_dir" = true ]; then
    printf 'php-darwin: preserved recovery files in %s\n' "$tmp_dir" >&2
  else
    rm -rf "$tmp_dir"
  fi
  exit "$cleanup_status"
}
trap php_darwin_install_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Optional pack preparation is read-only and overlaps the base PHP install.
# Node is optional: PHP-only installs and unavailable pack support keep working.
if [ -n "$extensions_input" ] && extension_node=$(command -v "${PHP_DARWIN_NODE:-node}"); then
  mkdir -p "$extension_dir" &&
    cat "$script_dir/install-extensions.cjs" > "$extension_dir/install-extensions.cjs" &&
    "$extension_node" "$extension_dir/install-extensions.cjs" select "$extension_dir" "$extensions_input" &&
    if [ -s "$extension_dir/requested.txt" ]; then
      "$extension_node" "$extension_dir/install-extensions.cjs" prefetch-requested "$extension_dir" \
        "$version" "$build" "$ts" "$arch" > "$extension_dir/prefetch.log" 2>&1 &
      extension_prefetch_pid=$!
    fi
fi

# Reading Homebrew trust, unlinking PHP, and downloading the cache are
# independent. Track the read-only and mutating workers separately so cleanup
# can stop trust queries while safely completing or rolling back unlinking.
for linked_php_path in "$brew_prefix/var/homebrew/linked"/php*; do
  [ -L "$linked_php_path" ] || continue
  linked_php_formula=${linked_php_path##*/}
  php_darwin_is_php_formula "$linked_php_formula" || continue
  linked_php_target=$(readlink "$linked_php_path") || \
    php_darwin_die "could not read the linked Homebrew formula $linked_php_formula"
  case "$linked_php_target" in "../../../Cellar/$linked_php_formula/"*) ;; *)
    php_darwin_die "invalid linked Homebrew formula target: $linked_php_target"
    ;;
  esac
  linked_php_reference=$(php_darwin_keg_formula_reference "$brew_prefix" "$linked_php_formula" \
    "${linked_php_target#../../../}" "$tap") || \
    php_darwin_die "could not resolve the installed Homebrew formula $linked_php_formula"
  # Unlink the validated installed rack. A qualified tap name asks Homebrew
  # to load the formula again and fails when its original tap was untapped.
  # The same bare name also lets native rollback relink that installed keg.
  linked_php_references+=("${linked_php_reference##*/}")
done
: > "$homebrew_prepare_phase_file" || php_darwin_die 'could not create the Homebrew preparation phase file'
(
  trust_status=0
  trust_json=$(bash "$script_dir/trust-store.sh" snapshot "$brew_prefix") || trust_status=$?
  if [ "$trust_status" -eq 78 ]; then
    trust_json=$(brew trust --json=v1) || exit 1
  elif [ "$trust_status" -ne 0 ]; then
    exit "$trust_status"
  fi
  if php_darwin_tap_trusted "$tap" "$trust_json"; then
    printf 'true\n' > "$tap_trust_file" || exit 1
  else
    trust_status=$?
    [ "$trust_status" -eq 1 ] || exit 1
    printf 'false\n' > "$tap_trust_file" || exit 1
  fi
  # Reuse the combined snapshot. Older Homebrew revisions pluralized this key
  # differently; an unknown schema can still use the selected collection.
  formula_trust_json=$(jq -c '
    if has("formulae") then .formulae elif has("formulas") then .formulas else empty end
  ' <<< "$trust_json") || exit 1
  [ -n "$formula_trust_json" ] || \
    formula_trust_json=$(brew trust --formula --json=v1) || exit 1
  jq -r '
    if type == "array" and all(.[]; type == "string") then .[]
    else error("invalid Homebrew formula trust response")
    end
  ' <<< "$formula_trust_json" > "$initial_formula_trust_file" || exit 1
) > "$homebrew_trust_log" 2>&1 &
homebrew_trust_pid=$!
(
  printf 'homebrew.tap-path\n' > "$homebrew_prepare_phase_file" || exit 1
  php_darwin_tap_repository_path "$tap" > "$tap_path_file" || exit 1
  if [ "${#linked_php_references[@]}" -gt 0 ]; then
    printf 'homebrew.unlink\n' > "$homebrew_prepare_phase_file" || exit 1
    php_darwin_unlink_formulae "$php_unlink_mode_file" "${linked_php_references[@]}" || exit 1
  fi
) > "$homebrew_prepare_log" 2>&1 &
homebrew_prepare_pid=$!

archive="$tmp_dir/$asset"
external_metadata=
cached_source_hash=
manifest_homebrew_commit=
manifest_php_src_commit=
manifest_php_semver=
manifest_source_hash=
manifest_download_asset=
manifest_archive_bytes=
manifest_extensions_commit=
manifest_from_embedded=false
release_archive_error=

php_darwin_use_release_manifest() {
  local manifest_file=$1
  local manifest_values

  manifest_values=$(php_darwin_validate_release_manifest \
    "$manifest_file" "$version" "$channel" "$asset") || return 1
  IFS=$'\t' read -r expected_hash manifest_homebrew_commit manifest_php_src_commit \
    manifest_php_semver manifest_source_hash manifest_download_asset manifest_extensions_commit \
    <<< "$manifest_values" || return 1
  [ -n "$expected_hash" ] && [ -n "$manifest_homebrew_commit" ] && \
    [ -n "$manifest_php_src_commit" ] && [ -n "$manifest_php_semver" ] && \
    [ -n "$manifest_source_hash" ] && [ -n "$manifest_download_asset" ] && \
    [ -n "$manifest_extensions_commit" ] || return 1
  [ "$manifest_php_src_commit" != - ] || manifest_php_src_commit=
  [ "$manifest_extensions_commit" != - ] || manifest_extensions_commit=
  manifest_archive_bytes=$(jq -er --arg asset "$asset" \
    '.assets[] | select(.name == $asset) | .bytes' "$manifest_file") || return 1
}

php_darwin_refresh_release_manifest() {
  manifest_url=${PHP_DARWIN_MANIFEST_URL:-}
  [ -n "$manifest_url" ] || manifest_url=$(php_darwin_release_manifest_url "$release_repository" "$version") || \
    php_darwin_die 'could not construct the release manifest URL'
  manifest_status=$(php_darwin_fetch_release_manifest "$release_repository" "$version" \
    "$release_manifest" "${PHP_DARWIN_MANIFEST_URL:-}") || php_darwin_die "could not request $manifest_url"
  [ "$manifest_status" = 200 ] || \
    php_darwin_die "could not fetch the PHP $version release manifest (HTTP $manifest_status)"
  php_darwin_use_release_manifest "$release_manifest" || \
    php_darwin_die 'release manifest did not match the requested PHP version'
  manifest_from_embedded=false
}

php_darwin_download_release_archive() {
  local archive_http_status
  local mirror_url
  local urls=()
  local destination
  local resume_bytes='' request_result received_bytes

  release_archive_error=
  release_url=${PHP_DARWIN_RELEASE_URL:-https://github.com/$release_repository/releases/download/php-$version/$manifest_download_asset}
  urls+=("$release_url")
  if [ -z "${PHP_DARWIN_RELEASE_URL:-}" ] || [ -n "${PHP_DARWIN_MIRROR_URL:-}" ]; then
    mirror_url=$(php_darwin_release_mirror "$release_repository" "$version") || return 1
    [ -z "$mirror_url" ] || urls+=("$mirror_url/$manifest_download_asset")
    if [ -n "$mirror_url" ] && [ "${PHP_DARWIN_PREFER_MIRROR:-false}" = true ]; then
      urls=("$mirror_url/$manifest_download_asset" "$release_url")
    fi
  fi
  release_archive_error=not-found
  for release_url in "${urls[@]}"; do
    destination=$archive
    [ -z "$resume_bytes" ] || destination="$archive.remaining"
    request_result=0
    archive_http_status=$(php_darwin_request_release "$release_url" "$destination" \
      1024 10 300 "$resume_bytes") || request_result=$?
    if [ "$request_result" -ne 0 ]; then
      [ "$release_archive_error" = checksum ] || release_archive_error=download
      if [ "$archive_http_status" = 200 ] && [ -s "$archive" ] && [ -z "$resume_bytes" ]; then
        received_bytes=$(wc -c < "$archive" | tr -d '[:space:]')
        if [ "$received_bytes" -lt "$manifest_archive_bytes" ]; then
          # A known incomplete prefix cannot match the digest. Start the mirror
          # immediately and authenticate the complete combined archive below.
          resume_bytes=$received_bytes
        elif [ "$received_bytes" -eq "$manifest_archive_bytes" ]; then
          # A timeout can arrive after the last byte. Still require its digest;
          # a corrupt complete response must restart at the next origin.
          php_darwin_start_archive_hash "$archive"
          php_darwin_wait_for_archive_hash
          if [ "$actual_hash" = "$expected_hash" ]; then release_archive_error=; return 0; fi
          release_archive_error=checksum
        fi
      fi
      continue
    fi
    if [ -n "$resume_bytes" ]; then
      case "$archive_http_status" in
        206) cat "$destination" >> "$archive" || return 1 ;;
        # Range is optional at the origin. A full response replaces the prefix.
        200) mv "$destination" "$archive" || return 1 ;;
      esac
    fi
    if [ "$archive_http_status" != 200 ] && \
      { [ "$archive_http_status" != 206 ] || [ -z "$resume_bytes" ]; }; then
      if [ "$archive_http_status" != 404 ] && [ "$release_archive_error" != checksum ]; then
        release_archive_error=download
      fi
      continue
    fi
    php_darwin_start_archive_hash "$archive"
    php_darwin_wait_for_archive_hash
    if [ "$actual_hash" = "$expected_hash" ]; then
      release_archive_error=
      return 0
    fi
    printf 'php-darwin: checksum mismatch from %s; trying the next origin\n' "$release_url" >&2
    release_archive_error=checksum
    resume_bytes=
  done
  return 1
}

PHP_DARWIN_PHASE=fetch
metadata_copy="$tmp_dir/cache-metadata.json"
if [ -n "$local_archive" ]; then
  archive=$local_archive
  checksum="$local_archive.sha256"
  external_metadata="$(dirname "$local_archive")/${asset%.tar.zst}.json"
  [ -f "$archive" ] || php_darwin_die "archive not found: $archive"
  [ -f "$checksum" ] || php_darwin_die "checksum not found: $checksum"
  [ -f "$external_metadata" ] || php_darwin_die "metadata not found: $external_metadata"
  expected_hash=$(php_darwin_checksum_from_file "$checksum" "$asset") || \
    php_darwin_die "checksum file does not contain $asset"
  php_darwin_start_archive_hash "$archive"
  cp "$external_metadata" "$metadata_copy" || php_darwin_die 'could not copy external cache metadata'
  php_darwin_wait_for_archive_hash
  [ "$actual_hash" = "$expected_hash" ] || php_darwin_die "checksum mismatch for $asset"
else
  release_repository=${PHP_DARWIN_RELEASE_REPOSITORY:-$package_release_repository}
  [[ "$release_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
    php_darwin_die "invalid release repository: $release_repository"
  release_manifest="$tmp_dir/php-$version-manifest.json"
  if php_darwin_read_config release-manifest.json > "$release_manifest" 2>/dev/null; then
    if php_darwin_use_release_manifest "$release_manifest"; then
      manifest_from_embedded=true
    else
      php_darwin_refresh_release_manifest
    fi
  else
    php_darwin_refresh_release_manifest
  fi
  if ! php_darwin_download_release_archive; then
    if [ "$manifest_from_embedded" = true ] && [ "$release_archive_error" = not-found ] && \
      [ -z "${PHP_DARWIN_RELEASE_URL:-}" ]; then
      printf 'Embedded release archive was retired; retrying with the current release manifest\n' >&2
      php_darwin_refresh_release_manifest
      if ! php_darwin_download_release_archive; then
        case "$release_archive_error" in
          checksum) php_darwin_die "checksum mismatch for the current release archive $asset" ;;
          *) php_darwin_die "could not download the current release archive from $release_url" ;;
        esac
      fi
    else
      case "$release_archive_error" in
        checksum) php_darwin_die "checksum mismatch for $asset" ;;
        *) php_darwin_die "could not download $release_url" ;;
      esac
    fi
  fi
  [ "$actual_hash" = "$expected_hash" ] || php_darwin_die "checksum mismatch for $asset"
  bash "$script_dir/read-metadata.sh" "$archive" "$internal_metadata_path" "$metadata_copy" || \
    php_darwin_die 'could not read metadata from the verified release archive'
fi

PHP_DARWIN_PHASE=cache.metadata
expected_metadata_commit=${HOMEBREW_PHP_COMMIT:-$manifest_homebrew_commit}
metadata_values=$(php_darwin_validate_cache_metadata "$metadata_copy" "$version" "$build" "$ts" "$arch" \
  "$brew_prefix" "$macos_major" "$expected_metadata_commit" "$manifest_php_src_commit" \
  "$current_version" "$tap_snapshot" "$minimum_macos" "$platform_key" \
  "$manifest_extensions_commit") || \
  php_darwin_die 'cache metadata did not match the runner or request'
IFS=$'\t' read -r metadata_homebrew_commit cached_source_hash target_keg_relative pecl_extension \
  metadata_php_semver <<< "$metadata_values" || \
  php_darwin_die 'could not parse the validated cache metadata'
if [ -n "$manifest_source_hash" ]; then
  [ "$cached_source_hash" = "$manifest_source_hash" ] || \
    php_darwin_die 'cache metadata source hash does not match the release manifest'
  [ "$metadata_php_semver" = "$manifest_php_semver" ] || \
    php_darwin_die 'cache PHP version does not match the release manifest'
fi

existing_kegs="$tmp_dir/existing-kegs.txt"
changed_formulae_file="$tmp_dir/changed-formulae.txt"
packages_file="$tmp_dir/packages.tsv"
package_kegs_file="$tmp_dir/package-kegs.txt"
links_file="$tmp_dir/links.tsv"
installed_links_file="$tmp_dir/installed-links.tsv"
managed_paths_file="$tmp_dir/managed-paths.txt"
exclude_file="$tmp_dir/existing-paths.txt"
metadata_records_file="$tmp_dir/metadata-records.tsv"
state_paths_inventory="$tmp_dir/state-paths-inventory.txt"
extension_paths_inventory="$tmp_dir/extension-paths-inventory.tsv"
tap_formulae_file="$tmp_dir/tap-formulae.txt"
: > "$packages_file" || php_darwin_die 'could not create the Homebrew package receipt list'
: > "$package_kegs_file" || php_darwin_die 'could not create the Homebrew keg path list'
: > "$managed_paths_file" || php_darwin_die 'could not create the managed archive path list'
: > "$links_file" || php_darwin_die 'could not create the Homebrew link list'
: > "$installed_links_file" || php_darwin_die 'could not create the installed Homebrew link list'
: > "$state_paths_inventory" || php_darwin_die 'could not create the Homebrew state path list'
: > "$extension_paths_inventory" || php_darwin_die 'could not create the cached extension path list'
jq -er '
  if ((.tap_formulae // []) | length) > 0 then .tap_formulae[] else .formula end
' "$metadata_copy" > "$tap_formulae_file" || \
  php_darwin_die 'could not read embedded custom-tap formulae'
jq -r '[
    (.packages[] | ["package", .name, .opt_target, (.keg_only | tostring)]),
    (.packages[] | ["keg", (.opt_target | ltrimstr("../"))]),
    (.links[] | ["managed", .path]),
    ((.extensions // [])[] | ["extension", .name, .type, .path]),
    ((.extensions // [])[] | ["managed", .path]),
    (.packages[] | ["managed", ("opt/" + .name)]),
    (.links[] | ["link", .path, .target])
  ][] | @tsv' "$metadata_copy" > "$metadata_records_file" || \
  php_darwin_die 'could not read embedded Homebrew installation records'
awk -F '\t' -v packages="$packages_file" -v kegs="$package_kegs_file" \
  -v extensions="$extension_paths_inventory" -v managed="$managed_paths_file" -v links="$links_file" '
  $1 == "package" && NF == 4 { print $2 "\t" $3 "\t" $4 > packages; next }
  $1 == "keg" && NF == 2 { print $2 > kegs; next }
  $1 == "extension" && NF == 4 { print $2 "\t" $3 "\t" $4 > extensions; next }
  $1 == "managed" && NF == 2 { print $2 > managed; next }
  $1 == "link" && NF == 3 { print $2 "\t" $3 > links; next }
  { exit 1 }
' "$metadata_records_file" || php_darwin_die 'could not split embedded Homebrew installation records'
jq -er '.state_paths[]' "$metadata_copy" > "$state_paths_inventory" || \
  php_darwin_die 'could not read embedded Homebrew state paths'
cat "$state_paths_inventory" >> "$managed_paths_file" || \
  php_darwin_die 'could not add embedded Homebrew state paths'
while IFS= read -r state_path; do
  if [ ! -e "$brew_prefix/$state_path" ] && [ ! -L "$brew_prefix/$state_path" ]; then
    printf '%s\n' "$state_path" >> "$new_state_paths_file" || \
      php_darwin_die "could not record new Homebrew state path: $state_path"
  fi
done < "$state_paths_inventory"
# The first two metadata columns are validated above; only the path is needed here.
# shellcheck disable=SC2034
while IFS=$'\t' read -r extension extension_type extension_path; do
  [ -n "$extension_path" ] || continue
  if [ ! -e "$brew_prefix/$extension_path" ] && [ ! -L "$brew_prefix/$extension_path" ]; then
    printf '%s\n' "$extension_path" >> "$new_state_paths_file" || \
      php_darwin_die "could not record new cached extension path: $extension_path"
  fi
done < "$extension_paths_inventory"

PHP_DARWIN_PHASE=homebrew.prepare.wait
php_darwin_wait_for_homebrew_prepare
case "$tap_path" in
  "$brew_prefix/Library/Taps/"*|"$brew_prefix/Homebrew/Library/Taps/"*) ;;
  *) php_darwin_die "unexpected Homebrew tap path: $tap_path" ;;
esac
[ ! -L "$tap_path" ] || php_darwin_die "Homebrew tap path is a symlink: $tap_path"
tap_path_backup=$(php_darwin_tap_backup_path "$brew_prefix" "$tap_path" "$tmp_dir") || \
  php_darwin_die 'could not resolve the Homebrew tap backup path'
tap_path_state=$(php_darwin_prepare_tap_path "$tap_path" "$tap_path_backup") || \
  php_darwin_die "could not prepare the $tap tap path"
case "$tap_path_state" in
  backed-up) tap_path_backed_up=true ;;
  absent|git) ;;
  *) php_darwin_die "invalid $tap tap-path state: $tap_path_state" ;;
esac

formula_trust_references=()
if [ "$tap_was_trusted" = false ]; then
  while IFS= read -r package_name; do
    formula_reference="$tap/$package_name"
    grep -Fxq "$formula_reference" "$initial_formula_trust_file" || \
      formula_trust_references+=("$formula_reference")
  done < "$tap_formulae_file"
fi

PHP_DARWIN_PHASE=cache.validation

# Keep older kegs side-by-side as Homebrew does during an upgrade. An exact
# cached keg must be removed before extraction; otherwise Homebrew only needs
# to unlink the active PHP formulae. Formula-managed post-install state is
# moved aside so the cache can replace it and restore it if installation fails.
PHP_DARWIN_PHASE=homebrew.prepare
if [ -e "$tap_snapshot_path" ] || [ -L "$tap_snapshot_path" ]; then
  [ -d "$tap_snapshot_path" ] && [ ! -L "$tap_snapshot_path" ] || \
    php_darwin_die "Homebrew tap snapshot path is not a directory: $tap_snapshot"
  mv "$tap_snapshot_path" "$tap_snapshot_backup" || \
    php_darwin_die 'could not back up the existing Homebrew tap snapshot'
  tap_snapshot_backed_up=true
fi
if [ -d "$brew_prefix/$target_keg_relative" ]; then
  target_opt_path="$brew_prefix/opt/$formula"
  if [ -L "$target_opt_path" ]; then
    target_opt_previous=$(readlink "$target_opt_path") || \
      php_darwin_die "could not read the existing Homebrew opt link for $formula"
    case "$target_opt_previous" in "../Cellar/$formula/"*) ;; *)
      php_darwin_die "unsupported existing Homebrew opt link for $formula: $target_opt_previous"
      ;;
    esac
    printf '%s\t%s\n' "$formula" "$target_opt_previous" >> "$previous_opt_links" || \
      php_darwin_die "could not preserve the existing Homebrew opt link for $formula"
  fi
  mv "$brew_prefix/$target_keg_relative" "$target_keg_backup" || \
    php_darwin_die "could not back up the existing cached $formula keg"
  target_keg_backed_up=true
fi
php_darwin_postinstall_paths "$version" "$formula" "$build" "$ts" > "$postinstall_candidates_file" || \
  php_darwin_die 'could not resolve formula-managed post-install paths'
: > "$postinstall_paths_file" || php_darwin_die 'could not create the post-install path list'
while IFS= read -r postinstall_path; do
  if grep -Fxq "$postinstall_path" "$state_paths_inventory"; then
    printf '%s\n' "$postinstall_path" >> "$postinstall_paths_file" || \
      php_darwin_die "could not record $postinstall_path"
  else
    case "$postinstall_path" in */pear.conf)
      php_darwin_die "cache metadata omitted $postinstall_path"
      ;;
    esac
  fi
done < "$postinstall_candidates_file"
mkdir -p "$postinstall_backup_dir" || php_darwin_die 'could not create the post-install backup directory'
while IFS= read -r postinstall_path; do
  [ -n "$postinstall_path" ] || continue
  if [ -e "$brew_prefix/$postinstall_path" ] || [ -L "$brew_prefix/$postinstall_path" ]; then
    mkdir -p "$postinstall_backup_dir/${postinstall_path%/*}" || \
      php_darwin_die "could not prepare the backup for $postinstall_path"
    mv "$brew_prefix/$postinstall_path" "$postinstall_backup_dir/$postinstall_path" || \
      php_darwin_die "could not back up $postinstall_path"
  fi
done < "$postinstall_paths_file"
if [ -e "$brew_prefix/$pear_path" ] || [ -L "$brew_prefix/$pear_path" ]; then
  mv "$brew_prefix/$pear_path" "$pear_backup" || php_darwin_die "could not back up $pear_path"
  pear_backed_up=true
fi
rm -f "$brew_prefix/$internal_metadata_path" || php_darwin_die 'could not remove stale archive metadata'
printf '%s\n' "$internal_metadata_path" >> "$managed_paths_file" || \
  php_darwin_die 'could not add the embedded metadata path'
printf '%s\n' "$pear_path" >> "$managed_paths_file" || \
  php_darwin_die 'could not add the formula-managed PEAR path'
printf '%s\n' "$tap_snapshot" >> "$managed_paths_file" || \
  php_darwin_die 'could not add the Homebrew tap snapshot path'
cat "$postinstall_paths_file" >> "$managed_paths_file" || \
  php_darwin_die 'could not add formula-managed post-install paths'
LC_ALL=C sort -u "$managed_paths_file" -o "$managed_paths_file" || \
  php_darwin_die 'could not sort managed archive paths'
# Active Homebrew records are normally unlinked by preparation. Also handle
# stale command links without a linked-keg record, before exclusion inventory.
bash "$script_dir/php-command-links.sh" prepare "$brew_prefix" "$command_links_journal" "$links_file" "$formula" || \
  php_darwin_die 'could not prepare the archived PHP command links'
bash "$script_dir/existing-paths.sh" "$brew_prefix" "$exclude_file" \
  "$archive_roots_file" \
  "$existing_kegs" "$managed_paths_file" "$package_kegs_file" || \
  php_darwin_die 'could not record existing Homebrew paths'
dependency_links_file="$tmp_dir/dependency-links.txt"
bash "$script_dir/install-state.sh" plan "$brew_prefix" \
  "$packages_file" "$existing_kegs" "$changed_formulae_file" "$dependency_links_file" || \
  php_darwin_die 'could not plan cached Homebrew package changes'
while IFS= read -r package_name; do
  [ "$package_name" = "$formula" ] || linked_dependency_references+=("$package_name")
done < "$dependency_links_file"
[ -s "$changed_formulae_file" ] || php_darwin_die 'cache extraction would not add any Homebrew kegs'
grep -Fxq "$formula" "$changed_formulae_file" || php_darwin_die "cache extraction would not add $formula"
if [ "${#linked_dependency_references[@]}" -gt 0 ]; then
  PHP_DARWIN_PHASE=homebrew.unlink
  PHP_DARWIN_UNLINK_PATHS_FILE="$managed_paths_file" \
    php_darwin_unlink_formulae "$dependency_unlink_mode_file" "${linked_dependency_references[@]}" >/dev/null || \
    php_darwin_die 'could not unlink the existing Homebrew dependencies'
  # Unlinked paths must be eligible for extraction and link verification.
  bash "$script_dir/existing-paths.sh" "$brew_prefix" "$exclude_file" \
    "$archive_roots_file" "$existing_kegs" "$managed_paths_file" "$package_kegs_file" || \
    php_darwin_die 'could not refresh existing Homebrew paths after dependency unlinking'
fi

# Preserved PEAR and configuration files were moved aside for rollback. Do not
# extract replacement copies that would immediately be discarded on success.
if [ "$pear_backed_up" = true ]; then
  printf '%s\n' "$pear_path" >> "$exclude_file" || exit 1
fi
while IFS= read -r postinstall_path; do
  if [ -e "$postinstall_backup_dir/$postinstall_path" ] || [ -L "$postinstall_backup_dir/$postinstall_path" ]; then
    printf '%s\n' "$postinstall_path" >> "$exclude_file" || exit 1
  fi
done < "$postinstall_paths_file"
# Existing paths (including complete excluded subtrees) remain user-owned.
# Verify and roll back only links the cache will add.
awk -F '\t' '
  FILENAME == ARGV[1] { excluded[$0]=1; next }
  {
    path=$1
    while (1) {
      if (path in excluded) next
      if (!sub("/[^/]+$", "", path)) break
    }
    print
  }
' "$exclude_file" "$links_file" > "$installed_links_file" || \
  php_darwin_die 'could not select Homebrew links installed by the cache'
[ -s "$installed_links_file" ] || php_darwin_die 'cache extraction would not add any Homebrew links'

PHP_DARWIN_PHASE=archive.extract
archive_mutation_started=true
tap_snapshot_extracted=true
bash "$script_dir/extract.sh" "$archive" "$brew_prefix" "$exclude_file" \
  "$managed_paths_file" "$package_kegs_file" || \
  php_darwin_die "could not extract $asset into Homebrew"

PHP_DARWIN_PHASE=homebrew.tap
[ -d "$tap_snapshot_path/.git" ] && [ ! -L "$tap_snapshot_path" ] || \
  php_darwin_die 'cache did not contain a valid Homebrew tap snapshot'
bash "$script_dir/validate-tap.sh" "$tap_snapshot_path" "$version" '' \
  "$tap_repository" "$metadata_homebrew_commit" "$tap_branch" >/dev/null || \
  php_darwin_die 'cached Homebrew tap snapshot validation failed'
if [ -e "$tap_path" ]; then
  php_darwin_is_git_worktree "$tap_path" || \
    php_darwin_die "installed Homebrew tap is not a Git repository: $tap_path"
  bash "$script_dir/tap-action.sh" "$tap_path" "$tap_snapshot_path" "$version" \
    "$cached_source_hash" "$tap_repository" "$metadata_homebrew_commit" "$tap_branch" \
    > "$tap_action_file" 2> "$tap_log" &
  tap_pid=$!
else
  tap_parent=${tap_path%/*}
  [ ! -L "$tap_parent" ] || php_darwin_die "Homebrew tap owner path is a symlink: $tap_parent"
  mkdir -p "$tap_parent" || php_darwin_die "could not create the Homebrew tap owner path: $tap_parent"
  mv "$tap_snapshot_path" "$tap_path" || php_darwin_die "could not install the $tap snapshot"
  tap_snapshot_extracted=false
  tap_installed=true
fi

PHP_DARWIN_PHASE=homebrew.receipts
metadata="$brew_prefix/$internal_metadata_path"
[ -f "$metadata" ] || php_darwin_die 'cache did not contain embedded installation metadata'
cmp -s "$metadata" "$metadata_copy" || \
  php_darwin_die 'extracted installation metadata changed during archive extraction'
rm -f "$metadata" || php_darwin_die 'could not remove embedded installation metadata'
bash "$script_dir/install-state.sh" receipts "$brew_prefix" \
  "$packages_file" "$changed_formulae_file" "$previous_opt_links" || \
  php_darwin_die 'could not install cached Homebrew package opt links'
if [ -n "$tap_pid" ] && [ ! -f "$tap_path/Formula/$formula.rb" ]; then
  php_darwin_wait_for_tap
fi
if [ "$tap_was_trusted" = false ]; then
  php_darwin_wait_for_tap
  PHP_DARWIN_PHASE=homebrew.trust
  if [ "${#formula_trust_references[@]}" -gt 0 ]; then
    printf 'Trusting %s installed Homebrew formula(s) from %s\n' \
      "${#formula_trust_references[@]}" "$tap"
    trust_status=0
    bash "$script_dir/trust-store.sh" add "$brew_prefix" "$tap" "$formula_trust_pending" \
      "${formula_trust_references[@]}" || trust_status=$?
    if [ "$trust_status" -eq 78 ]; then
      printf '%s\n' "${formula_trust_references[@]}" > "$formula_trust_pending" || \
        php_darwin_die 'could not record formula trust added by the cache installation'
      brew trust --formula "${formula_trust_references[@]}" || \
        php_darwin_die "could not trust installed Homebrew formulae from $tap"
    elif [ "$trust_status" -ne 0 ]; then
      php_darwin_die "could not merge installed Homebrew formula trust for $tap"
    fi
    mv "$formula_trust_pending" "$formula_trust_marker" || \
      php_darwin_die 'could not commit formula trust added by the cache installation'
  fi
fi
PHP_DARWIN_PHASE=homebrew.dependencies
[ -z "$tap_pid" ] || dependencies_started_with_pending_tap=true
php_darwin_check_installed_dependencies > "$missing_log" 2>&1 &
missing_pid=$!

PHP_DARWIN_PHASE=homebrew.configure
[ "$pear_backed_up" = true ] || [ -d "$brew_prefix/$pear_path" ] || \
  php_darwin_die "cache did not install $pear_path"
while IFS= read -r postinstall_path; do
  [ -n "$postinstall_path" ] || continue
  if [ -e "$postinstall_backup_dir/$postinstall_path" ] || \
    [ -L "$postinstall_backup_dir/$postinstall_path" ]; then
    rm -rf "${brew_prefix:?}/${postinstall_path:?}" || \
      php_darwin_die "could not replace cached $postinstall_path with the existing file"
    mkdir -p "$brew_prefix/${postinstall_path%/*}" || \
      php_darwin_die "could not restore the parent for $postinstall_path"
    mv "$postinstall_backup_dir/$postinstall_path" "$brew_prefix/$postinstall_path" || \
      php_darwin_die "could not preserve $postinstall_path"
    printf '%s\n' "$postinstall_path" >> "$postinstall_restored_file" || \
      php_darwin_die "could not record the restored $postinstall_path"
  fi
done < "$postinstall_paths_file"
if [ "$pear_backed_up" = true ]; then
  rm -rf "${brew_prefix:?}/${pear_path:?}" || php_darwin_die "could not replace cached $pear_path"
  mkdir -p "$brew_prefix/${pear_path%/*}" || php_darwin_die "could not restore the parent for $pear_path"
  mv "$pear_backup" "$brew_prefix/$pear_path" || php_darwin_die "could not preserve $pear_path"
  pear_backed_up=false
  pear_restored=true
fi
mkdir -p "$brew_prefix/lib/php/pecl/$pecl_extension" \
  "$brew_prefix/$pear_path/doc" "$brew_prefix/$pear_path/data" "$brew_prefix/$pear_path/cfg" \
  "$brew_prefix/$pear_path/htdocs" "$brew_prefix/$pear_path/test" || \
  php_darwin_die 'could not create formula-managed PEAR and PECL directories'
# Existing PEAR settings may intentionally use a custom shared directory.
# Validate the archive defaults only when this transaction supplied them.
if ! grep -Fxq "etc/php/$config_id/pear.conf" "$postinstall_restored_file"; then
  [ -s "$brew_prefix/etc/php/$config_id/pear.conf" ] || php_darwin_die 'cache did not install the Homebrew PEAR configuration'
  grep -Fq "$brew_prefix/$pear_path" "$brew_prefix/etc/php/$config_id/pear.conf" || \
    php_darwin_die 'cached PEAR configuration has the wrong shared path'
  grep -Fq "$brew_prefix/lib/php/pecl/$pecl_extension" "$brew_prefix/etc/php/$config_id/pear.conf" || \
    php_darwin_die 'cached PEAR configuration has the wrong extension path'
fi
[ -L "$brew_prefix/opt/$formula/pecl" ] && [ -d "$brew_prefix/opt/$formula/pecl" ] || \
  php_darwin_die 'cached PHP PECL link has no shared directory target'

PHP_DARWIN_PHASE=homebrew.link
bash "$script_dir/verify-links.sh" "$brew_prefix" "$installed_links_file" || \
  php_darwin_die 'cached Homebrew links did not match the archive metadata'

PHP_DARWIN_PHASE=runtime.verify
expected_runtime_version=$metadata_php_semver
[ "$channel" != nightly ] || expected_runtime_version="$metadata_php_semver-dev"
bash "$script_dir/verify-runtime.sh" "$brew_prefix" "$formula" "$expected_runtime_version" \
  "$extension_paths_inventory" || php_darwin_die 'cached PHP installation validation failed'
PHP_DARWIN_PHASE=homebrew.dependencies
php_darwin_resolve_tap_and_dependencies
runtime_verified=true
PHP_DARWIN_PHASE=homebrew.finalize

if [ "$tap_snapshot_backed_up" = true ]; then
  if { [ ! -e "$tap_snapshot_path" ] && [ ! -L "$tap_snapshot_path" ]; } && \
    { mv "$tap_snapshot_backup" "$tap_snapshot_path" 2>/dev/null || \
      { command -v sudo >/dev/null 2>&1 && sudo -n mv "$tap_snapshot_backup" "$tap_snapshot_path"; }; }; then
    tap_snapshot_backed_up=false
  else
    preserve_tmp_dir=true
    printf 'php-darwin: restore the previous cache tap with: sudo mv %s %s\n' \
      "$tap_snapshot_backup" "$tap_snapshot_path" >&2
  fi
fi
if [ "$tap_restore_after_install" = true ]; then
  # Formula trust is needed only while the temporary cached tap is active.
  # Dependency link operations use bare rack names and do not load core formulae.
  if php_darwin_remove_tap_path "$brew_prefix" "$tap_path"; then
    tap_installed=false
    if php_darwin_restore_tap_path "$tap_path" "$tap_path_backup"; then
      tap_path_backed_up=false
      tap_restore_after_install=false
      if ! php_darwin_restore_formula_trust; then
        preserve_tmp_dir=true
      fi
    else
      printf 'php-darwin: restore the original tap with: sudo mv %s %s\n' \
        "$tap_path_backup" "$tap_path" >&2
    fi
  else
    printf 'php-darwin: remove %s, then restore the original tap with: sudo mv %s %s\n' \
      "$tap_path" "$tap_path_backup" "$tap_path" >&2
  fi
elif [ "$tap_path_backed_up" = true ]; then
  # The new tap is committed at this point. A best-effort cleanup failure must
  # not trigger rollback from a backup that may already be partially removed.
  tap_path_backed_up=false
  tap_installed=false
  php_darwin_remove_tap_backup "$brew_prefix" "$tap_path_backup" || \
    printf 'php-darwin: could not remove the retired Homebrew tap backup: %s\n' \
      "$tap_path_backup" >&2
fi
# Install only after the complete base transaction has passed its runtime and
# preservation checks. A missing or incompatible optional pack leaves normal
# extension installation available to callers such as setup-php.
if [ -n "$extension_prefetch_pid" ]; then
  wait "$extension_prefetch_pid" || true
  extension_prefetch_pid=
  cat "$extension_dir/prefetch.log"
  "$extension_node" "$extension_dir/install-extensions.cjs" activate "$extension_dir" \
    "$metadata_copy" "$brew_prefix/etc/php/$config_id/conf.d" ||
    printf 'php-darwin: optional packs unavailable; using the caller extension installer\n' >&2
fi
printf 'Installed PHP %s (%s, %s, %s) from %s\n' \
  "$expected_runtime_version" "$build" "$ts" "$arch" "$asset"
