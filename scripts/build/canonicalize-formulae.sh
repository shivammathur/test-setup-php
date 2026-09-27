#!/usr/bin/env bash

jq -er '
  if (.formulae | type) == "array" and
    (.formulae | length) > 0 and
    all(.formulae[]; (.name | type == "string" and test("^[A-Za-z0-9@+._-]+$")))
  then
    .formulae[].name
  else
    error("invalid Homebrew formula information")
  end
' | LC_ALL=C sort -u
pipeline_status=("${PIPESTATUS[@]}")
[ "${pipeline_status[0]}" -eq 0 ] && [ "${pipeline_status[1]}" -eq 0 ]
