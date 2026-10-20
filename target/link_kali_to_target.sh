#!/usr/bin/env bash
# Connects the Kali fleet to the target. When a student attacks from inside
# their Kali VM, the target sees that VM's Elastic IP -- not the student's
# home IP. This merges every Kali VM's IP from kali_fleet/kali_roster_output.csv
# into roster.csv (replacing, never duplicating, each student's row).
# Then run ./sync_roster.sh to apply it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"
ROSTER="$HERE/roster.csv"
touch "$ROSTER"

roster_rows | while IFS=',' read -r SID IID IP PORT KEY || [ -n "$SID" ]; do
  [ -z "$SID" ] && continue
  grep -v "^${SID}," "$ROSTER" > "$ROSTER.tmp" || true
  mv "$ROSTER.tmp" "$ROSTER"
  echo "${SID},${IP}" >> "$ROSTER"
  echo "linked: $SID -> $IP"
done
echo "== roster.csv updated. Now run: ./sync_roster.sh =="
