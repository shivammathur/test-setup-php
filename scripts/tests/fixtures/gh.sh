#!/usr/bin/env bash

printf '%s\n' "$*" >> "${GH_LOG:?}"
case "${1:-}/${2:-}" in
  api/*)
    case "${GH_FAIL_API_MATCH:-}" in
      '') exit 0 ;;
      *) case "$*" in *"$GH_FAIL_API_MATCH"*) exit 1 ;; *) exit 0 ;; esac ;;
    esac
    ;;
  release/view)
    if [ "${GH_RELEASE_EXISTS:-false}" = true ]; then
      if [ -n "${GH_RELEASE_ASSETS_JSON:-}" ]; then
        cat "$GH_RELEASE_ASSETS_JSON" || exit 1
      else
        printf '{"assets":[]}\n'
      fi
      exit 0
    fi
    exit 1
    ;;
  release/create) exit 0 ;;
  release/delete-asset)
    case "${GH_FAIL_DELETE_MATCH:-}" in
      '') exit 0 ;;
      *) case "$*" in *"$GH_FAIL_DELETE_MATCH"*) exit 1 ;; *) exit 0 ;; esac ;;
    esac
    ;;
  release/download)
    destination=
    patterns=()
    previous=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --dir) shift; destination=${1:-} ;;
        --pattern) shift; patterns+=("${1:-}") ;;
      esac
      shift
    done
    [ -n "$destination" ] && [ -d "${GH_PREVIOUS_ASSETS:-}" ] || exit 1
    mkdir -p "$destination" || exit 1
    for pattern in "${patterns[@]}"; do
      case "${GH_FAIL_DOWNLOAD_MATCH:-}" in
        '') ;;
        *) case "$pattern" in *"$GH_FAIL_DOWNLOAD_MATCH"*) exit 1 ;; esac ;;
      esac
      previous="${GH_PREVIOUS_ASSETS}/$pattern"
      [ -f "$previous" ] || exit 1
      cp "$previous" "$destination/" || exit 1
    done
    exit 0
    ;;
  release/upload)
    for argument in "$@"; do
      case "${GH_FAIL_UPLOAD_ONCE_MATCH:-}" in
        '') ;;
        *) case "$argument" in *"$GH_FAIL_UPLOAD_ONCE_MATCH"*)
          attempts=0
          [ ! -f "${GH_FAIL_UPLOAD_ONCE_MARKER:?}" ] || read -r attempts < "$GH_FAIL_UPLOAD_ONCE_MARKER"
          if [ "$attempts" -lt "${GH_FAIL_UPLOAD_ATTEMPTS:-1}" ]; then
            printf '%s\n' "$((attempts + 1))" > "$GH_FAIL_UPLOAD_ONCE_MARKER" || exit 1
            exit 1
          fi
          ;;
        esac ;;
      esac
      case "${GH_FAIL_UPLOAD_MATCH:-}" in
        '') ;;
        *) case "$argument" in *"$GH_FAIL_UPLOAD_MATCH"*) exit 1 ;; esac ;;
      esac
      case "$argument" in *-manifest.json)
        cp "$argument" "${GH_MANIFEST:?}" || exit 1
        ;;
      */install.sh)
        [ -z "${GH_INSTALLER:-}" ] || cp "$argument" "$GH_INSTALLER" || exit 1
        ;;
      esac
    done
    exit 0
    ;;
esac
printf 'Unexpected gh fixture command: %s\n' "$*" >&2
exit 1
