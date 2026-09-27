#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

formula=${1:?}
mode=${2:-platforms}
case "$mode" in platforms|source) ;; *) php_darwin_die "invalid formula input mode: $mode" ;; esac
platforms=$(php_darwin_read_config platforms.json | jq -er '
  to_entries | map([.key,.value.platform_key,(.value.minimum_macos | tostring)] | join(":")) | join(" ")
') || php_darwin_die 'could not read cache build platforms'

# Project only the simple bottle DSL emitted by brew bottle. Unknown syntax is
# retained verbatim, so it can cause a rebuild but can never hide a source edit.
# Everything outside the bottle block remains byte-for-byte line content.
LC_ALL=C awk -v platforms="$platforms" -v mode="$mode" '
  BEGIN {
    count=split(platforms, targets, " ")
    split("tiger leopard snow_leopard lion mountain_lion mavericks yosemite el_capitan sierra high_sierra mojave catalina", old, " ")
    for (i in old) versions[old[i]]=10 + (i + 3) / 100
    versions["big_sur"]=11; versions["monterey"]=12; versions["ventura"]=13
    versions["sonoma"]=14; versions["sequoia"]=15; versions["tahoe"]=26
    versions["golden_gate"]=27
  }
  function flush(    i,j,target,tag,os_name,arch,selected,fallback,all_tag) {
    if (unknown) {
      printf "%s", block
    } else if (mode != "source") {
      for (i=1; i<=count; i++) {
        split(targets[i], target, ":")
        selected=""; fallback=""; all_tag=""
        for (j=1; j<=bottles; j++) {
          tag=tags[j]
          sub(/^x86_64_/, "", tag)
          if (tag == target[2]) selected=lines[j]
          if (tag == "all") all_tag=lines[j]
          arch=(tag ~ /^arm64_/ ? "arm64" : "x86_64")
          os_name=tag; sub(/^arm64_/, "", os_name)
          if (fallback == "" && arch == target[1] && os_name in versions && versions[os_name] <= target[3])
            fallback=lines[j]
        }
        # Homebrew prefers an exact tag, then all, then the first compatible
        # older bottle in declaration order. No match means a source build.
        if (selected == "") selected=all_tag
        if (selected == "") selected=fallback
        if (selected != "") {
          print "# php-darwin bottle input: " target[1]
          printf "%s%s\n", common, selected
        }
      }
    }
    in_bottle=0
  }
  !in_bottle && /^  bottle do$/ {
    in_bottle=1; block=$0 "\n"; common=""; bottles=0; unknown=0
    next
  }
  in_bottle {
    block=block $0 "\n"
    if ($0 == "  end") { flush(); next }
    line=$0
    if (line ~ /^[[:space:]]*$/ || line ~ /^    #/) next
    if ((line ~ /^    root_url "[^"\\]+"$/ && line !~ /#\{/) || line ~ /^    rebuild [0-9]+$/) {
      common=common line "\n"; next
    }
    if (line ~ /^    sha256[[:space:]]+(cellar: (:[a-z_]+|"[^"\\]+"),[[:space:]]+)?[a-z0-9_]+:[[:space:]]+"[0-9a-f]+"$/) {
      # Normalize alignment padding only, never the contents of a string.
      sub(/^    sha256[[:space:]]+/, "sha256 ", line)
      match(line, /[a-z0-9_]+:[[:space:]]+"[0-9a-f]+"$/)
      prefix=substr(line, 1, RSTART-1)
      checksum=substr(line, RSTART)
      sub(/[[:space:]]+$/, " ", prefix)
      sub(/:[[:space:]]+/, ": ", checksum)
      line=prefix checksum
      tag=checksum; sub(/:.*$/, "", tag)
      bottles++; tags[bottles]=tag; lines[bottles]=line
      next
    }
    unknown=1
  }
  !in_bottle { print }
  END { if (in_bottle) printf "%s", block }
' "$formula" || php_darwin_die "could not project bottle inputs for $formula"
