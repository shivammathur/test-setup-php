#!/usr/bin/env bash
set -euo pipefail

php_version="${PHP_VERSION:?}"
source_name="${SOURCE:?}"
audit_dir="${RUNNER_TEMP:?}/runtime-library-audit"
baseline="$audit_dir/runner-baseline.tsv"
after="$audit_dir/after-setup.tsv"
objects_file="$audit_dir/runtime-objects.tsv"
dependencies_file="$audit_dir/runtime-dependencies.tsv"
runtime_packages_file="$audit_dir/runtime-packages.tsv"
cache_candidates_file="$audit_dir/cache-candidates.tsv"
runner_owned_file="$audit_dir/runner-owned-runtime-packages.tsv"
disabled_extensions_file="$audit_dir/disabled-extension-objects.tsv"
unavailable_packages_file="$audit_dir/unavailable-packages.txt"
summary="${GITHUB_STEP_SUMMARY:-$audit_dir/summary.md}"
php_ubuntu_dir="$GITHUB_WORKSPACE/php-ubuntu"

mkdir -p "$audit_dir"
: > "$unavailable_packages_file"

normalize_package() {
  local package=$1
  package="${package%%,*}"
  package="${package%%:*}"
  printf '%s\n' "$package"
}

write_package_list() {
  local output=$1

  dpkg-query -W -f='${binary:Package}\t${Version}\n' \
    | awk -F '\t' '{ package=$1; sub(/:.*/, "", package); print package "\t" $2 }' \
    | sort -u > "$output"
}

package_present() {
  local package=$1
  local package_file=$2

  awk -F '\t' -v package="$package" '$1 == package { found=1 } END { exit found ? 0 : 1 }' "$package_file"
}

package_owner() {
  local path=$1
  local owner resolved

  owner="$(dpkg-query -S "$path" 2>/dev/null | grep -v '^diversion ' | head -n 1 || true)"
  if [[ -z $owner ]]; then
    resolved="$(readlink -f "$path" 2>/dev/null || true)"
    if [[ -n $resolved && $resolved != "$path" ]]; then
      owner="$(dpkg-query -S "$resolved" 2>/dev/null | grep -v '^diversion ' | head -n 1 || true)"
    fi
  fi

  if [[ -z $owner ]]; then
    printf 'unowned\n'
  else
    normalize_package "${owner%%:*}"
  fi
}

package_state() {
  local package=$1
  local in_baseline=false
  local after_setup=false

  if [[ $package != "unowned" && $package != "unresolved" ]]; then
    package_present "$package" "$baseline" && in_baseline=true
    package_present "$package" "$after" && after_setup=true
  fi

  printf '%s\t%s\n' "$in_baseline" "$after_setup"
}

install_base_tools() {
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl file gnupg jq sudo zstd
}

install_php_builder() {
  local installer="/tmp/php-builder-install-$php_version.sh"

  curl -fsSL -o "$installer" "https://github.com/shivammathur/php-builder/releases/download/$php_version/install.sh"
  bash "$installer" github "$php_version" release nts
}

ondrej_packages() {
  local version=$1
  local packages=(
    "php$version"
    "php$version-amqp"
    "php$version-apcu"
    "php$version-ast"
    "php$version-bcmath"
    "php$version-bz2"
    "php$version-cgi"
    "php$version-cli"
    "php$version-common"
    "php$version-curl"
    "php$version-dba"
    "php$version-dev"
    "php$version-ds"
    "php$version-embed"
    "php$version-enchant"
    "php$version-fpm"
    "php$version-gd"
    "php$version-gmp"
    "php$version-igbinary"
    "php$version-imagick"
    "php$version-imap"
    "php$version-interbase"
    "php$version-intl"
    "php$version-ldap"
    "php$version-mbstring"
    "php$version-memcache"
    "php$version-memcached"
    "php$version-mongodb"
    "php$version-msgpack"
    "php$version-mysql"
    "php$version-oauth"
    "php$version-odbc"
    "php$version-opcache"
    "php$version-pcov"
    "php$version-pgsql"
    "php$version-phpdbg"
    "php$version-pspell"
    "php$version-readline"
    "php$version-redis"
    "php$version-snmp"
    "php$version-soap"
    "php$version-sqlite3"
    "php$version-sybase"
    "php$version-tidy"
    "php$version-xdebug"
    "php$version-xml"
    "php$version-xsl"
    "php$version-yaml"
    "php$version-zip"
    "php$version-zmq"
  )

  case "$version" in
    5.6)
      packages+=("php$version-json" "php$version-mcrypt" "php$version-recode" "php$version-xmlrpc")
      ;;
    7.0|7.1)
      packages+=("php$version-json" "php$version-mcrypt" "php$version-recode" "php$version-sodium" "php$version-xmlrpc")
      ;;
    7.2|7.3)
      packages+=("php$version-json" "php$version-recode" "php$version-xmlrpc")
      ;;
    7.4|8.3|8.4|8.5|8.6)
      packages+=("php$version-json" "php$version-xmlrpc")
      ;;
  esac

  printf '%s\n' "${packages[@]}" | sort -u
}

install_ondrej() {
  local available=()
  local package

  sudo -E bash -c 'set -euo pipefail; cd "$1"; . ./scripts/packages.sh; add_ppa' bash "$php_ubuntu_dir"

  if ! apt-cache policy "php$php_version-cli" | awk '/Candidate:/ && $2 != "(none)" { found=1 } END { exit found ? 0 : 1 }'; then
    {
      echo "status=skipped"
      echo "reason=php$php_version-cli is not available from Ondrej packages for this runner"
    } | tee "$audit_dir/status.env"
    return 2
  fi

  while IFS= read -r package; do
    if apt-cache policy "$package" | awk '/Candidate:/ && $2 != "(none)" { found=1 } END { exit found ? 0 : 1 }'; then
      available+=("$package")
    else
      printf '%s\n' "$package" >> "$unavailable_packages_file"
    fi
  done < <(ondrej_packages "$php_version")

  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${available[@]}"
  switch_php_version
}

switch_php_version() {
  local tool

  for tool in phar phar.phar php php-cgi php-config phpize phpdbg; do
    sudo update-alternatives --set "$tool" "/usr/bin/$tool$php_version" 2>/dev/null || true
  done
  sudo update-alternatives --set php-cgi-bin "/usr/lib/cgi-bin/php$php_version" 2>/dev/null || true
  sudo update-alternatives --set php-fpm "/usr/sbin/php-fpm$php_version" 2>/dev/null || true
}

extension_dir() {
  php-config"$php_version" --extension-dir 2>/dev/null \
    || php-config --extension-dir 2>/dev/null \
    || php -r 'echo ini_get("extension_dir");' 2>/dev/null
}

extension_enabled() {
  local extension=$1

  php -d display_errors=0 -r "exit(extension_loaded('$extension') ? 0 : 1);" >/dev/null 2>&1
}

record_context() {
  # shellcheck disable=SC1091
  . /etc/os-release
  {
    echo "source=$source_name"
    echo "php=$php_version"
    echo "runner=${RUNNER_NAME:-}"
    echo "runner_os=${RUNNER_OS:-}"
    echo "label=${ImageOS:-}"
    echo "ubuntu=$VERSION_ID"
    echo "codename=$VERSION_CODENAME"
    echo "arch=$(dpkg --print-architecture)"
  } | tee "$audit_dir/context.env"
}

collect_objects() {
  local ext_dir
  ext_dir="$(extension_dir || true)"
  printf 'kind\tobject\textension\tenabled\tpackage\tpackage_in_runner_baseline\tpackage_after_setup\n' > "$objects_file"

  {
    for path in \
      "/usr/bin/php$php_version" \
      "/usr/bin/php-cgi$php_version" \
      "/usr/bin/phpdbg$php_version" \
      "/usr/lib/cgi-bin/php$php_version" \
      "/usr/lib/libphp$php_version.so" \
      "/usr/lib/apache2/modules/libphp$php_version.so" \
      "/usr/sbin/php-fpm$php_version"; do
      [[ -e $path ]] && printf 'php\t%s\t\ttrue\n' "$path"
    done

    if [[ -n $ext_dir && -d $ext_dir ]]; then
      find "$ext_dir" -type f -name '*.so' -print | sort -u | while IFS= read -r path; do
        extension="$(basename "$path" .so)"
        enabled=false
        extension_enabled "$extension" && enabled=true
        printf 'extension\t%s\t%s\t%s\n' "$path" "$extension" "$enabled"
      done
    fi

    if [[ -n $ext_dir && -e "$ext_dir/imagick.so" ]] || php -m 2>/dev/null | grep -qi '^imagick$'; then
      find /usr/lib -type f -path '*ImageMagick-*' -path '*modules-*' -name '*.so' -print 2>/dev/null \
        | sort -u \
        | while IFS= read -r path; do
          printf 'imagemagick-module\t%s\t%s\ttrue\n' "$path" "$(basename "$path" .so)"
        done
    fi
  } | sort -u | while IFS=$'\t' read -r kind object extension enabled; do
    if file -b "$object" 2>/dev/null | grep -q 'ELF'; then
      package="$(package_owner "$object")"
      read -r in_baseline after_setup < <(package_state "$package")
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$object" "$extension" "$enabled" "$package" "$in_baseline" "$after_setup" >> "$objects_file"
    fi
  done

  awk -F '\t' 'NR > 1 && $1 == "extension" && $4 == "false"' "$objects_file" > "$disabled_extensions_file"
}

collect_dependencies() {
  local after_setup in_baseline library object package path

  printf 'kind\tobject\textension\tenabled\tlibrary\tpath\tpackage\tpackage_in_runner_baseline\tpackage_after_setup\n' > "$dependencies_file"

  tail -n +2 "$objects_file" | while IFS=$'\t' read -r kind object extension enabled _object_package _object_in_baseline _object_after_setup; do
    { ldd "$object" 2>&1 || true; } | awk '
      /=>/ {
        library=$1
        path=$3
        if (path == "not" && $4 == "found") {
          print library "\tnot found"
        } else if (path ~ /^\//) {
          print library "\t" path
        }
      }
      /^[[:space:]]*\// {
        print $1 "\t" $1
      }
    ' | sort -u | while IFS=$'\t' read -r library path; do
      package="unresolved"
      if [[ $path == /* ]]; then
        package="$(package_owner "$path")"
      fi
      read -r in_baseline after_setup < <(package_state "$package")
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$object" "$extension" "$enabled" "$library" "$path" "$package" "$in_baseline" "$after_setup" >> "$dependencies_file"
    done
  done
}

write_runtime_package_reports() {
  printf 'package\tpackage_in_runner_baseline\tpackage_after_setup\n' > "$runtime_packages_file"
  awk -F '\t' 'NR > 1 && $7 != "unowned" && $7 != "unresolved" { print $7 "\t" $8 "\t" $9 }' "$dependencies_file" \
    | sort -u >> "$runtime_packages_file"

  awk -F '\t' 'NR == 1 || (NR > 1 && $2 == "false")' "$runtime_packages_file" > "$cache_candidates_file"
  awk -F '\t' 'NR == 1 || (NR > 1 && $2 == "true")' "$runtime_packages_file" > "$runner_owned_file"
}

write_summary() {
  local disabled_count missing_count runner_owned_count runtime_count status
  status="$(sed -n 's/^status=//p' "$audit_dir/status.env" 2>/dev/null || true)"
  status="${status:-completed}"
  runtime_count="$(tail -n +2 "$runtime_packages_file" 2>/dev/null | wc -l | xargs)"
  missing_count="$(tail -n +2 "$cache_candidates_file" 2>/dev/null | wc -l | xargs)"
  runner_owned_count="$(tail -n +2 "$runner_owned_file" 2>/dev/null | wc -l | xargs)"
  disabled_count="$(wc -l < "$disabled_extensions_file" 2>/dev/null | xargs)"

  {
    echo "## Runtime library audit"
    echo
    echo "| Field | Value |"
    echo "| --- | --- |"
    echo "| Source | $source_name |"
    echo "| PHP | $php_version |"
    echo "| Status | $status |"
    echo "| Runtime packages | $runtime_count |"
    echo "| Missing from runner | $missing_count |"
    echo "| Already in runner | $runner_owned_count |"
    echo "| Disabled extension objects checked | $disabled_count |"
    echo
    echo "### Missing from runner"
    echo
    echo '```text'
    tail -n +2 "$cache_candidates_file" 2>/dev/null | cut -f 1 | sed -n '1,160p'
    echo '```'
    echo
    echo "### Already in runner"
    echo
    echo '```text'
    tail -n +2 "$runner_owned_file" 2>/dev/null | cut -f 1 | sed -n '1,160p'
    echo '```'
    echo
    echo "### Disabled extension objects"
    echo
    echo '```text'
    cut -f 2-4 "$disabled_extensions_file" 2>/dev/null | sed -n '1,160p'
    echo '```'
    echo
    if [[ -s $unavailable_packages_file ]]; then
      echo "### Unavailable Ondrej packages"
      echo
      echo '```text'
      sed -n '1,160p' "$unavailable_packages_file"
      echo '```'
      echo
    fi
  } >> "$summary"
}

write_package_list "$baseline"
install_base_tools

case "$source_name" in
  php-builder)
    install_php_builder
    ;;
  ondrej)
    set +e
    install_ondrej
    install_status=$?
    set -e
    if [[ $install_status -eq 2 ]]; then
      write_package_list "$after"
      record_context
      printf 'kind\tobject\textension\tenabled\tpackage\tpackage_in_runner_baseline\tpackage_after_setup\n' > "$objects_file"
      printf 'kind\tobject\textension\tenabled\tlibrary\tpath\tpackage\tpackage_in_runner_baseline\tpackage_after_setup\n' > "$dependencies_file"
      printf 'package\tpackage_in_runner_baseline\tpackage_after_setup\n' > "$runtime_packages_file"
      cp "$runtime_packages_file" "$cache_candidates_file"
      cp "$runtime_packages_file" "$runner_owned_file"
      : > "$disabled_extensions_file"
      write_summary
      exit 0
    elif [[ $install_status -ne 0 ]]; then
      exit "$install_status"
    fi
    ;;
  *)
    echo "Unsupported source: $source_name" >&2
    exit 1
    ;;
esac

write_package_list "$after"
record_context
collect_objects
collect_dependencies
write_runtime_package_reports
write_summary
