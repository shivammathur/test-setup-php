profile_run() {
  local profile_name=$1
  shift
  local profile_start profile_end profile_status
  profile_start=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')
  "$@"
  profile_status=$?
  profile_end=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')
  printf '%s\t%s\t%s\t%s\t%s\n' "$profile_name" "$profile_start" "$profile_end" "$profile_status" "$*" >> "$PROFILE_DIR/stages.tsv"
  return "$profile_status"
}

profile_brew() {
  if [ "$SCENARIO" = recovery ] && [ "$1" = install ] && [[ "$*" = *homebrew-extensions/yaml@8.4* ]] && [ ! -e "$PROFILE_DIR/injected" ]; then
    touch "$PROFILE_DIR/injected"
    echo 'Injected first extension install failure' >&2
    return 1
  fi
  command brew "$@"
}
brew() { profile_run brew profile_brew "$@"; }

for profile_function in setup_cached_versions add_brew_extension install_brew_extension add_brew_tap fetch_brew_tap update_dependencies git_retry; do
  if declare -f "$profile_function" >/dev/null; then
    eval "$(declare -f "$profile_function" | sed "1s/$profile_function/profile_original_$profile_function/")"
    eval "$profile_function() { profile_run $profile_function profile_original_$profile_function \"\$@\"; }"
  fi
done
eval "$(declare -f setup_php | sed '1s/setup_php/profile_original_setup_php/')"
setup_php() {
  profile_run setup_php profile_original_setup_php "$@" || return $?
  shasum -a 256 "$(command -v php)" > "$PROFILE_DIR/php-before.sha256"
}
