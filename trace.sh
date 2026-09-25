# BASH_ENV diagnostics only: the setup-php and release installer bytes are unchanged.
profile_phase() {
  if [ -n "${PHP_DARWIN_PHASE:-}" ] && [ "$PHP_DARWIN_PHASE" != "${profile_previous_phase:-}" ]; then
    printf 'PROFILE phase pid=%s seconds=%s name=%s\n' "$$" "$SECONDS" "$PHP_DARWIN_PHASE" >&2
    printf 'phase\t%s\t%s\t%s\n' "$$" "$SECONDS" "$PHP_DARWIN_PHASE" >> "$PROFILE_DIR/events.tsv"
    profile_previous_phase=$PHP_DARWIN_PHASE
  fi
}
trap profile_phase DEBUG

curl() {
  local format='' url='' label='' result=0
  local arguments=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -w|--write-out) format=$2; shift 2 ;;
      --write-out=*) format=${1#*=}; shift ;;
      *)
        case "$1" in http://*|https://*) url=${1%%\?*} ;; esac
        arguments+=("$1"); shift ;;
    esac
  done
  label=${url##*/}
  "$PROFILE_REAL_CURL" "${arguments[@]}" --write-out "${format}%{stderr}PROFILE curl pid=$$ seconds=$SECONDS asset=$label status=%{http_code} dns=%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} first_byte=%{time_starttransfer} total=%{time_total} bytes=%{size_download} speed=%{speed_download}\n%{stdout}" || result=$?
  return "$result"
}

bash() {
  local result=0
  if [ "${repo:-}" = php-darwin ] && [ "${1:-}" = /tmp/install.sh ]; then
    printf 'PROFILE installer start seconds=%s\n' "$SECONDS" >&2
    /usr/bin/time -l /bin/bash "$@" || result=$?
    printf 'PROFILE installer end seconds=%s status=%s\n' "$SECONDS" "$result" >&2
    return "$result"
  fi
  command bash "$@"
}
