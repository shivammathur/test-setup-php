#!/usr/bin/env bash
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} = true && $EUID -eq 0 ]] || exit 1
awk '/^# Variables$/ {exit} {print}' "${ACTION_ROOT:?}/src/scripts/linux.sh" > /tmp/linux-functions.sh
cat > /tmp/run-case.sh <<'CASE'
set -euo pipefail
source /tmp/linux-functions.sh
sudo() { "$@"; }
update_lists() { echo update >> /tmp/events; }
fix_broken_packages() { echo repair >> /tmp/events; }
filter_packages() { printf '%s\n' "$@"; }
mock_install() {
  [[ -x /usr/bin/apt-fast ]] || return 99
  if [[ "$existing_marker" = false && -e /etc/dpkg/dpkg.cfg.d/force-confnew ]]; then return 98; fi
  if [[ "$entry" != nested && $(grep -c '^install ' /tmp/events) -eq 0 && "$BASHPID" != "$caller_pid" ]]; then return 97; fi
  printf 'install %s\n' "$*" >> /tmp/events
  case "$mode" in
    fail) return 42 ;;
    retry) [[ $(grep -c '^install ' /tmp/events) -gt 1 ]] || return 42 ;;
  esac
}
apt_install=mock_install
caller_pid=$BASHPID
case "$entry" in
  helper) self_hosted_helper ;;
  direct|nested|repeat)
    link_apt_fast
    before=$(trap -p EXIT)
    if [[ "$entry" = nested ]]; then
      (install_packages simulated-package)
    else
      install_packages simulated-package
    fi
    [[ $(trap -p EXIT) = "$before" ]] || { echo 'Caller EXIT trap was replaced' >&2; exit 90; }
    [[ -x /usr/bin/apt-fast ]] || { echo 'apt-fast removed before caller exited' >&2; exit 91; }
    if [[ "$entry" = repeat ]]; then
      install_packages second-package
    fi
    ;;
esac
exit "$final_status"
CASE
passed=0
failed=0
for existing_apt in false true; do
  for existing_marker in false true; do
    for entry in direct helper nested repeat; do
      for mode in success retry fail; do
        for final_status in 0 17; do
          rm -f /usr/bin/apt-fast /etc/dpkg/dpkg.cfg.d/force-confnew
          : > /tmp/events
          if "$existing_apt"; then ln -s /bin/true /usr/bin/apt-fast; fi
          if "$existing_marker"; then echo original-marker > /etc/dpkg/dpkg.cfg.d/force-confnew; fi
          status=0
          export entry mode final_status existing_marker
          bash /tmp/run-case.sh > /tmp/case-output 2>&1 || status=$?
          expected=$final_status
          [[ "$mode" != fail ]] || expected=42
          problems=()
          [[ "$status" -eq "$expected" ]] || problems+=("exit=$status expected=$expected")
          if "$existing_apt"; then
            [[ -L /usr/bin/apt-fast && $(readlink /usr/bin/apt-fast) = /bin/true ]] || problems+=('existing apt-fast changed')
          else
            [[ ! -e /usr/bin/apt-fast && ! -L /usr/bin/apt-fast ]] || problems+=('temporary apt-fast leaked')
          fi
          if "$existing_marker"; then
            [[ -f /etc/dpkg/dpkg.cfg.d/force-confnew && $(cat /etc/dpkg/dpkg.cfg.d/force-confnew) = original-marker ]] || problems+=('existing marker changed')
          else
            [[ ! -e /etc/dpkg/dpkg.cfg.d/force-confnew ]] || problems+=('temporary marker leaked')
          fi
          calls=1
          [[ "$mode" = success ]] || calls=2
          if [[ "$entry" = repeat && "$mode" != fail ]]; then ((calls+=1)); fi
          [[ $(grep -c '^install ' /tmp/events) -eq "$calls" ]] || problems+=('unexpected install attempts')
          if ((${#problems[@]})); then
            printf 'FAIL apt=%s marker=%s entry=%s mode=%s exit=%s: %s\n' "$existing_apt" "$existing_marker" "$entry" "$mode" "$final_status" "${problems[*]}"
            cat /tmp/case-output
            ((failed+=1))
          else
            ((passed+=1))
          fi
        done
      done
    done
  done
done
printf 'Result: %s passed; %s failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
