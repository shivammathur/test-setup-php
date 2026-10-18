from pathlib import Path

Path('reports').mkdir(exist_ok=True)
script = Path('setup-php/src/scripts/unix.sh')
text = script.read_text()
needle = '  get -q -e /tmp/install.sh '
assert text.count(needle) == 1
replacement = '''  if [ "$repo" = php-ubuntu ]; then
    export PS4='+${EPOCHREALTIME} ${FUNCNAME[0]:-main}:${LINENO}: '
    /usr/bin/time -v bash -x "$GITHUB_WORKSPACE/cache/scripts/install.sh" "${args[@]}" >"$GITHUB_WORKSPACE/reports/install.log" 2>&1
    return $?
  fi
'''
script.write_text(text.replace(needle, replacement + needle))
