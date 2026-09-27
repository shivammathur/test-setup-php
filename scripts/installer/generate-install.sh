#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

root=$(cd "$script_dir/../.." && pwd)
files="$root/conf/install-files"
template="$root/templates/install.sh.in"
output=${1:-$root/scripts/install.sh}
work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-generate.XXXXXX") || \
  php_darwin_die 'could not create the standalone installer staging directory'
trap 'rm -rf "$work_dir"' EXIT
library="$work_dir/library.sh"
config="$work_dir/config.sh"
helpers="$work_dir/helpers.sh"
install="$work_dir/install.sh"
generated="$work_dir/generated.sh"
next="$work_dir/next.sh"
input_count=0
seen_inputs="$work_dir/inputs.txt"
release_manifest=${PHP_DARWIN_RELEASE_MANIFEST:-}

if [ -n "$release_manifest" ]; then
  [ -f "$release_manifest" ] || php_darwin_die "release manifest is missing: $release_manifest"
  ! grep -Fxq PHP_DARWIN_RELEASE_MANIFEST "$release_manifest" || \
    php_darwin_die 'release manifest contains the standalone installer delimiter'
fi

: > "$seen_inputs" || php_darwin_die 'could not create the standalone installer input list'
while IFS= read -r relative extra; do
  [ -n "$relative" ] || continue
  case "$relative" in \#*) continue ;; esac
  [ -z "$extra" ] || php_darwin_die "invalid standalone installer input: $relative $extra"
  case "$relative" in scripts/*|conf/*) ;; *) php_darwin_die "unsafe standalone installer input: $relative" ;; esac
  case "$relative" in /*|*'/../'*|../*|*/..|*'//'* )
    php_darwin_die "unsafe standalone installer input: $relative"
    ;;
  esac
  [ -f "$root/$relative" ] || php_darwin_die "standalone installer input is missing: $relative"
  ! grep -Fxq "$relative" "$seen_inputs" || php_darwin_die "duplicate standalone installer input: $relative"
  printf '%s\n' "$relative" >> "$seen_inputs" || php_darwin_die "could not record $relative"
  input_count=$((input_count + 1))
done < "$files"

grep -Fxq scripts/installer/install-package.sh "$seen_inputs" || php_darwin_die 'standalone installer entry point is missing'
grep -Fxq scripts/lib/lib.sh "$seen_inputs" || php_darwin_die 'standalone installer library is missing'

{
  printf '# Source: scripts/lib/lib.sh\n'
  awk '
    NR == 1 && /^#!/ { next }
    /^php_darwin_root=/ { next }
    /^php_darwin_read_config\(\)/ { skipping_config=1; next }
    skipping_config && /^}$/ { skipping_config=0; next }
    !skipping_config { print }
  ' "$root/scripts/lib/lib.sh"
} > "$library" || php_darwin_die 'could not stage the standalone installer library'
if grep -Eq '^php_darwin_root=' "$library"; then
  php_darwin_die 'standalone installer library retained the repository root'
fi

{
  printf 'php_darwin_read_config() {\n'
  printf "  case \"\${1:-}\" in\n"
  while IFS= read -r relative; do
    case "$relative" in conf/*)
      name=${relative#conf/}
      delimiter=PHP_DARWIN_CONFIG_$(printf '%s' "$name" | tr '[:lower:].-' '[:upper:]__')
      ! grep -Fxq "$delimiter" "$root/$relative" || \
        php_darwin_die "standalone configuration contains its delimiter: $relative"
      printf '    %s)\n' "$name"
      printf "      cat <<'%s'\n" "$delimiter"
      cat "$root/$relative" || php_darwin_die "could not read $relative"
      printf '%s\n' "$delimiter"
      printf '      ;;\n'
      ;;
    esac
  done < "$seen_inputs"
  printf '    release-manifest.json)\n'
  printf "      cat <<'PHP_DARWIN_RELEASE_MANIFEST'\n"
  if [ -n "$release_manifest" ]; then
    cat "$release_manifest" || php_darwin_die 'could not embed the release manifest'
  else
    printf '{}\n'
  fi
  printf 'PHP_DARWIN_RELEASE_MANIFEST\n'
  printf '      ;;\n'
  cat <<'PHP_DARWIN_CONFIG_DEFAULT'
    *) printf 'php-darwin: unknown embedded configuration: %s\n' "$1" >&2; return 1 ;;
PHP_DARWIN_CONFIG_DEFAULT
  printf '  esac\n'
  printf '}\n'
} > "$config" || php_darwin_die 'could not stage the standalone installer configuration'

: > "$helpers" || php_darwin_die 'could not create the standalone installer helper library'
while IFS= read -r relative; do
  case "$relative" in
    scripts/installer/install-package.sh|scripts/lib/lib.sh|conf/*) continue ;;
    scripts/installer/install-extensions.cjs)
      {
        printf '\n# Source: %s\n' "$relative"
        printf 'php_darwin_extension_installer() {\n'
        printf "  cat <<'PHP_DARWIN_EXTENSION_INSTALLER'\n"
        cat "$root/$relative"
        printf 'PHP_DARWIN_EXTENSION_INSTALLER\n}\n'
      } >> "$helpers" || php_darwin_die "could not embed $relative"
      continue ;;
    scripts/*.sh) ;;
    *) php_darwin_die "unsupported standalone installer input: $relative" ;;
  esac
  helper_name=php_darwin_$(basename "$relative" .sh | tr '-' '_')
  {
    printf '\n# Source: %s\n' "$relative"
    printf '%s() (\n' "$helper_name"
    awk '
      NR == 1 && /^#!/ { next }
      /^script_dir=.*BASH_SOURCE/ { next }
      /^# shellcheck source=scripts\/lib\/lib\.sh$/ { next }
      /^\. "\$script_dir\/(\.\.\/lib\/)?lib\.sh"$/ { next }
      {
        gsub(/bash "\$script_dir\/\.\.\/lib\/source-hash\.sh"/, "php_darwin_source_hash")
        gsub(/bash "\$script_dir\/validate-tap\.sh"/, "php_darwin_validate_tap")
        print
      }
    ' "$root/$relative"
    printf ')\n'
  } >> "$helpers" || php_darwin_die "could not stage $relative"
done < "$seen_inputs"

{
  printf '# Source: scripts/installer/install-package.sh\n'
  awk '
    NR == 1 && /^#!/ { next }
    /^script_dir=.*BASH_SOURCE/ { next }
    /^# shellcheck source=scripts\/lib\/lib\.sh$/ { next }
    /^\. "\$script_dir\/(\.\.\/lib\/)?lib\.sh"$/ { next }
    {
      gsub(/cat "\$script_dir\/install-extensions\.cjs"/, "php_darwin_extension_installer")
      gsub(/bash "\$script_dir\/read-metadata\.sh"/, "php_darwin_read_metadata")
      gsub(/bash "\$script_dir\/existing-paths\.sh"/, "php_darwin_existing_paths")
      gsub(/bash "\$script_dir\/extract\.sh"/, "php_darwin_extract")
      gsub(/bash "\$script_dir\/validate-tap\.sh"/, "php_darwin_validate_tap")
      gsub(/bash "\$script_dir\/tap-action\.sh"/, "php_darwin_tap_action")
      gsub(/bash "\$script_dir\/verify-links\.sh"/, "php_darwin_verify_links")
      gsub(/bash "\$script_dir\/trust-store\.sh"/, "php_darwin_trust_store")
      gsub(/bash "\$script_dir\/check-dependencies\.sh"/, "php_darwin_check_dependencies")
      gsub(/bash "\$script_dir\/unlink-kegs\.sh"/, "php_darwin_unlink_kegs")
      gsub(/bash "\$script_dir\/php-command-links\.sh"/, "php_darwin_php_command_links")
      gsub(/bash "\$script_dir\/install-state\.sh"/, "php_darwin_install_state")
      gsub(/bash "\$script_dir\/verify-runtime\.sh"/, "php_darwin_verify_runtime")
      print
    }
  ' "$root/scripts/installer/install-package.sh"
} > "$install" || php_darwin_die 'could not stage the standalone installer entry point'

cp "$template" "$generated" || php_darwin_die 'could not stage the standalone installer template'
replace_marker() {
  local marker=$1
  local content=$2

  awk -v marker="$marker" -v content="$content" '
    $0 == marker {
      while ((getline line < content) > 0) print line
      close(content)
      found=1
      next
    }
    { print }
    END { if (!found) exit 1 }
  ' "$generated" > "$next" || php_darwin_die "could not populate $marker"
  mv "$next" "$generated" || php_darwin_die "could not update $marker"
}
replace_marker __PHP_DARWIN_LIBRARY__ "$library"
replace_marker __PHP_DARWIN_CONFIG__ "$config"
replace_marker __PHP_DARWIN_HELPERS__ "$helpers"
replace_marker __PHP_DARWIN_INSTALL__ "$install"

if grep -Eq '__PHP_DARWIN_[A-Z_]+__|base64|gzip -d|\$\$' "$generated"; then
  php_darwin_die 'standalone installer contains an encoded payload or an unresolved marker'
fi
if grep -Fq "\$script_dir/" "$generated"; then
  php_darwin_die 'standalone installer still refers to repository scripts'
fi
bash -n "$generated" || php_darwin_die 'generated standalone installer has invalid shell syntax'
chmod 0755 "$generated" || php_darwin_die 'could not make the standalone installer executable'
mkdir -p "${output%/*}" || php_darwin_die 'could not create the standalone installer output directory'
mv "$generated" "$output" || php_darwin_die 'could not update the standalone installer'
printf 'Generated %s from %s readable inputs (%s bytes)\n' \
  "$output" "$input_count" "$(wc -c < "$output" | tr -d '[:space:]')"
