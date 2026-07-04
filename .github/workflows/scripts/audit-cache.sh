#!/usr/bin/env bash
set -euo pipefail

audit_dir="$RUNNER_TEMP/cache-audit"
mkdir -p "$audit_dir"

after="$audit_dir/after.tsv"
apt_log="$audit_dir/apt-check.log"
dependency_report="$audit_dir/dependency-report.tsv"
baseline="$audit_dir/baseline.tsv"
delegate_report="$audit_dir/imagemagick-delegates.tsv"
elf_objects="$audit_dir/elf-objects.txt"
link_report="$audit_dir/elf-dependencies.tsv"
new_packages="$audit_dir/new-packages.tsv"
object_report="$audit_dir/php-object-packages.tsv"
summary="${GITHUB_STEP_SUMMARY:-$audit_dir/summary.md}"

package_present() {
  local package=$1
  local file=$2

  awk -F '\t' -v package="$package" '
    {
      name = $1
      sub(/:.*/, "", name)
      if ($1 == package || name == package) {
        found = 1
      }
    }
    END {
      exit found ? 0 : 1
    }
  ' "$file"
}

package_owner() {
  local path=$1
  local owner resolved

  owner="$(dpkg-query -S "$path" 2>/dev/null | head -n 1 || true)"
  if [[ -z $owner ]]; then
    resolved="$(readlink -f "$path" 2>/dev/null || true)"
    if [[ -n $resolved && $resolved != "$path" ]]; then
      owner="$(dpkg-query -S "$resolved" 2>/dev/null | head -n 1 || true)"
    fi
  fi

  if [[ -z $owner ]]; then
    echo "unowned"
    return
  fi

  owner="${owner%%:*}"
  owner="${owner%%,*}"
  owner="${owner%:*}"
  echo "$owner"
}

write_package_presence() {
  local package=$1
  local in_baseline=false
  local after_setup=false

  if [[ $package != "unowned" && $package != "unresolved" ]]; then
    package_present "$package" "$baseline" && in_baseline=true
    package_present "$package" "$after" && after_setup=true
  fi

  printf '%s\t%s\n' "$in_baseline" "$after_setup"
}

dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort > "$after"
comm -13 \
  <(awk -F '\t' '{ package=$1; sub(/:.*/, "", package); print package }' "$baseline" | sort -u) \
  <(awk -F '\t' '{ package=$1; sub(/:.*/, "", package); print package }' "$after" | sort -u) \
  > "$new_packages"

set +e
sudo apt-get check 2>&1 | tee "$apt_log"
apt_status=${PIPESTATUS[0]}
set -e

printf 'parent\tdependency\tdependency_in_runner_baseline\tdependency_after_setup\n' > "$dependency_report"
awk '
  /^[[:space:]][^[:space:]][^:]* : Depends:/ {
    parent=$1
    sub(/:$/, "", parent)
  }
  /Depends:/ {
    line=$0
    sub(/^.*Depends:[[:space:]]*/, "", line)
    dep=line
    sub(/[[:space:](<>=|].*$/, "", dep)
    if (parent != "" && dep != "") {
      print parent "\t" dep
    }
  }
' "$apt_log" | sort -u | while IFS=$'\t' read -r parent dependency; do
  read -r in_baseline after_setup < <(write_package_presence "$dependency")
  printf '%s\t%s\t%s\t%s\n' "$parent" "$dependency" "$in_baseline" "$after_setup" >> "$dependency_report"
done

printf 'object\tpackage\tpackage_in_runner_baseline\tpackage_after_setup\n' > "$object_report"
printf 'object\tlibrary\tpath\tpackage\tpackage_in_runner_baseline\tpackage_after_setup\n' > "$link_report"
: > "$elf_objects"

if command -v php >/dev/null 2>&1; then
  {
    for tool in php php-cgi php-fpm phpdbg; do
      command -v "$tool" 2>/dev/null || true
    done

    extension_dir="$(php-config --extension-dir 2>/dev/null || true)"
    if [[ -n $extension_dir && -d $extension_dir ]]; then
      find "$extension_dir" -type f -name '*.so' -print
    fi
  } | sort -u | while IFS= read -r object; do
    if [[ -f $object ]] && file -b "$object" | grep -q 'ELF'; then
      echo "$object"
    fi
  done > "$elf_objects"
fi

while IFS= read -r object; do
  package="$(package_owner "$object")"
  read -r in_baseline after_setup < <(write_package_presence "$package")
  printf '%s\t%s\t%s\t%s\n' "$object" "$package" "$in_baseline" "$after_setup" >> "$object_report"

  ldd_log="$audit_dir/ldd-$(basename "$object").txt"
  { ldd "$object" 2>&1 || true; } | tee "$ldd_log" | awk '
    /=>/ {
      library=$1
      path=$3
      if (path == "not" && $4 == "found") {
        path="not found"
      }
      if (path ~ /^\// || path == "not found") {
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
    read -r in_baseline after_setup < <(write_package_presence "$package")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$object" "$library" "$path" "$package" "$in_baseline" "$after_setup" >> "$link_report"
  done
done < "$elf_objects"

printf 'coder\tpath\tpackage\tpackage_in_runner_baseline\tpackage_after_setup\n' > "$delegate_report"
find /usr/lib -path '*ImageMagick-*' -path '*modules-*' -path '*coders*' -type f \
  \( -name 'djvu.*' -o -name 'jpeg.*' -o -name 'png.*' \) -print 2>/dev/null | sort -u | while IFS= read -r coder; do
  package="$(package_owner "$coder")"
  read -r in_baseline after_setup < <(write_package_presence "$package")
  printf '%s\t%s\t%s\t%s\t%s\n' "$(basename "$coder")" "$coder" "$package" "$in_baseline" "$after_setup" >> "$delegate_report"
done

{
  echo "## Package integrity"
  echo
  echo "apt-get check status: $apt_status"
  echo
  echo "| Parent package | Missing/skewed dependency | In runner baseline | After setup |"
  echo "| --- | --- | --- | --- |"
  tail -n +2 "$dependency_report" | while IFS=$'\t' read -r parent dependency in_baseline after_setup; do
    echo "| $parent | $dependency | $in_baseline | $after_setup |"
  done
  echo
  echo "## Packages added by setup"
  echo
  if [[ -s $new_packages ]]; then
    echo '```text'
    sed -n '1,120p' "$new_packages"
    echo '```'
  else
    echo "No packages were added after the runner baseline."
  fi
  echo
  echo "## PHP object packages"
  echo
  echo "| Object | Package | In runner baseline | After setup |"
  echo "| --- | --- | --- | --- |"
  tail -n +2 "$object_report" | while IFS=$'\t' read -r object package in_baseline after_setup; do
    echo "| \`$object\` | $package | $in_baseline | $after_setup |"
  done
  echo
  echo "## Shared library packages outside runner baseline"
  echo
  echo "| Library package | After setup |"
  echo "| --- | --- |"
  awk -F '\t' 'NR > 1 && $5 == "false" { print $4 "\t" $6 }' "$link_report" | sort -u | while IFS=$'\t' read -r package after_setup; do
    echo "| $package | $after_setup |"
  done
  echo
  echo "## ImageMagick coder packages"
  echo
  echo "| Coder | Package | In runner baseline | After setup |"
  echo "| --- | --- | --- | --- |"
  tail -n +2 "$delegate_report" | while IFS=$'\t' read -r coder _path package in_baseline after_setup; do
    echo "| $coder | $package | $in_baseline | $after_setup |"
  done
  echo
  echo "### apt-get check"
  echo
  echo '```text'
  tail -n 120 "$apt_log"
  echo '```'
} >> "$summary"

exit "$apt_status"
