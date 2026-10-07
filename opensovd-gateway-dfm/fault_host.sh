#!/bin/bash
# Created with AI assistance (Claude Opus 5.5, Anthropic).
#
# fault_host.sh – Ubuntu laptop (host) version.
# Shows Guardian fault states from the OpenSOVD gateway as a table.
# Requires: curl, jq, column   (sudo apt install -y curl jq)
#
# Usage:  ./fault_host.sh            once
#         watch -n 1 ./fault_host.sh live view
# OpenSOVD gateway (default): ./fault_host.sh
# Old SOVD fault bridge:      URL=http://127.0.0.1:7691/sovd/v1/components/battery/faults ./fault_host.sh
# Reads snake_case (bridge) and camelCase (gateway) status keys.

URL=${URL:-http://127.0.0.1:7690/sovd/v1/apps/battery/faults}

JSON=$(curl -s "$URL")
if [ -z "$JSON" ]; then
  echo "SOVD server not reachable at $URL"
  exit 1
fi

echo "$JSON" | jq -r '
  if .items then
    (["FAULT","STATE","EVER","COUNT"],
     (.items[] | [.code,
                  (if (.status.test_failed // .status.testFailed) then "FAULTY" else "ok" end),
                  (if (.status.test_failed_since_last_clear // .status.testFailedSinceLastClear) then "yes" else "no" end),
                  (.occurrence_counter // 0)])) | @tsv
  else
    "ERROR\t\(.)"
  end' | column -t -s $'\t'
