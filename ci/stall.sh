#!/bin/bash
# No output: the real source-build inactivity watchdog must terminate this tree.
trap '' TERM
printf '%s\n' "$$" >"$1/stall.pid"
date +%s >"$1/stall-started"
while :; do
  sleep 60
done
