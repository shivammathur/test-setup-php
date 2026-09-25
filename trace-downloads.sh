#!/usr/bin/env bash
# Experiment diagnostics only; preserve curl's original stdout and exit status.
[ -z "${PHP_DARWIN_TRACE_HELPER:-}" ] || . "$PHP_DARWIN_TRACE_HELPER"
curl() {
  local original_format='' argument destination='' installer=false status=0
  local arguments=()
  while [ "$#" -gt 0 ]; do
    argument=$1
    shift
    case "$argument" in
      -w|--write-out) original_format=$1; shift ;;
      -o|--output) destination=$1; arguments+=("$argument" "$1"); shift ;;
      *)
        arguments+=("$argument")
        case "$argument" in */extensions/install-extensions.cjs) installer=true ;; esac
        ;;
    esac
  done
  command curl "${arguments[@]}" --write-out "${original_format}%{stderr}curl phase=${PHP_DARWIN_PHASE:-setup} code=%{http_code} dns=%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} first=%{time_starttransfer} redirect=%{time_redirect} total=%{time_total} bytes=%{size_download}\n%{stdout}" 2>>"${PHP_DARWIN_DOWNLOAD_LOG:?}" || status=$?
  # Fetch the published script normally, then test the pinned candidate bytes.
  # Its network cost remains inside the measured action.
  if [ "$status" = 0 ] && [ "$installer" = true ]; then
    [ -n "$destination" ] || return 1
    cp "$GITHUB_WORKSPACE/php-cache/scripts/installer/install-extensions.cjs" "$destination" || return $?
    printf 'Using the checked-out extension installer candidate after normal download\n' >> "$PHP_DARWIN_DOWNLOAD_LOG"
  fi
  return "$status"
}
export -f curl

# Bash's timer adds no process startup and leaves tar's output/status intact.
tar() {
  local TIMEFORMAT="tar phase=${PHP_DARWIN_PHASE:-setup} seconds=%3R user=%3U system=%3S"
  { time command tar "$@"; } 2>>"${PHP_DARWIN_DOWNLOAD_LOG:?}"
}
export -f tar
