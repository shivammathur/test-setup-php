#!/usr/bin/env bash
set -euo pipefail
stage=$1
trace="evidence/$stage-requests.tsv"
cp /var/tmp/sury-key-qa/requests.tsv "$trace"
cat "$trace"
python3 qa/key_trace.py "$ROUTE" "$trace"
if [[ "$stage" == repeat ]]; then
  diff -u evidence/initial-requests.tsv "$trace"
fi
