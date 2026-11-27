set -eu
echo "$GITHUB_WORKSPACE/qa/bin" >> "$GITHUB_PATH"
python3 qa/server.py >"$RUNNER_TEMP/qa-server.log" 2>&1 &
for _ in {1..100}; do [[ ! -s $RUNNER_TEMP/qa-ports ]] || break; sleep 0.1; done
test -s "$RUNNER_TEMP/qa-ports"
