#!/usr/bin/env bash
# Experiment diagnostics only; preserve curl's original stdout and exit status.
[ -z "${PHP_DARWIN_TRACE_HELPER:-}" ] || . "$PHP_DARWIN_TRACE_HELPER"
curl() {
  local original_format='' argument
  local arguments=()
  while [ "$#" -gt 0 ]; do
    argument=$1
    shift
    case "$argument" in
      -w|--write-out) original_format=$1; shift ;;
      *) arguments+=("$argument") ;;
    esac
  done
  command curl "${arguments[@]}" --write-out "${original_format}%{stderr}curl phase=${PHP_DARWIN_PHASE:-setup} code=%{http_code} dns=%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} first=%{time_starttransfer} redirect=%{time_redirect} total=%{time_total} bytes=%{size_download}\n%{stdout}" 2>>"${PHP_DARWIN_DOWNLOAD_LOG:?}"
}
export -f curl
