#!/bin/bash
# Created with AI assistance (Claude Opus 5.5, Anthropic).
#
# faults.sh – AutoSD (Podman target) version.
# Shows Guardian fault states from the SOVD fault bridge as a table.
# Requires only: curl, python3   (no jq on the AutoSD image)
# Compatible with older python3 (no nested quotes in f-strings).
#
# Usage:  /root/faults.sh             once
#         watch -n 1 /root/faults.sh  live view
# Override the bridge address:  URL=http://<host>:7691/... /root/faults.sh

URL=${URL:-http://127.0.0.1:7691/sovd/v1/components/battery/faults}

JSON=$(curl -s "$URL")
if [ -z "$JSON" ]; then
  echo "bridge not reachable at $URL"
  exit 1
fi

echo "$JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if "items" not in d:
    print("ERROR", d)
    sys.exit(1)
row = "{:<25}{:<8}{:<6}{}"
print(row.format("FAULT", "STATE", "EVER", "COUNT"))
for f in d["items"]:
    s = f.get("status", {})
    state = "FAULTY" if s.get("test_failed") else "ok"
    ever = "yes" if s.get("test_failed_since_last_clear") else "no"
    print(row.format(f["code"], state, ever, f.get("occurrence_counter", 0)))
'
