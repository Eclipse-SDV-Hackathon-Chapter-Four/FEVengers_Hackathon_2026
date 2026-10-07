#!/bin/bash
# Created with AI assistance (Claude Opus 5.5, Anthropic).
#
# fault_host.sh – Ubuntu laptop (host) version.
# Shows Guardian fault states from the SOVD fault bridge as a table.
# Requires: curl, jq, column   (sudo apt install -y curl jq)
#
# Usage:  ./fault_host.sh            once
#         watch -n 1 ./fault_host.sh live view
# Override the bridge address:  URL=http://<host>:7691/... ./fault_host.sh

URL=${URL:-http://127.0.0.1:7691/sovd/v1/components/battery/faults}

JSON=$(curl -s "$URL")
if [ -z "$JSON" ]; then
  echo "bridge not reachable at $URL"
  exit 1
fi

echo "$JSON" | jq -r '
  if .items then
    (["FAULT","STATE","EVER","COUNT"],
     (.items[] | [.code,
                  (if .status.test_failed then "FAULTY" else "ok" end),
                  (if .status.test_failed_since_last_clear then "yes" else "no" end),
                  (.occurrence_counter // 0)])) | @tsv
  else
    "ERROR\t\(.)"
  end' | column -t -s $'\t'
