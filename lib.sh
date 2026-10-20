# Shared helpers, sourced by every script. Not meant to be run directly.
# Written for bash 3.2 (macOS's /bin/bash) -- no mapfile, no associative arrays.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
. "$ROOT/config.env"

KALI_TAG="${PROJECT}-kali"
KALI_ROSTER="$ROOT/kali_fleet/kali_roster_output.csv"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

# Remove a leading UTF-8 BOM in place. Excel/Numbers add one when re-saving a
# CSV, and it silently turns a "# comment" first line into a bogus student ID.
strip_bom() {
  [ -f "$1" ] || return 0
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
d = open(p, 'rb').read()
if d.startswith(b'\xef\xbb\xbf'):
    open(p, 'wb').write(d[3:])
PY
}

# Print one clean student ID per line from a students.csv: first column only,
# quotes/spaces/CR stripped, blanks and # comments skipped. Handles a last line
# with no trailing newline (a plain `while read` silently drops it).
student_ids() {
  strip_bom "$1"
  local sid _rest
  while IFS=',' read -r sid _rest || [ -n "$sid" ]; do
    sid="$(printf '%s' "$sid" | tr -d '" \r')"
    case "$sid" in ''|\#*) continue ;; esac
    printf '%s\n' "$sid"
  done < "$1"
}

# Iterate kali_roster_output.csv rows. Usage:
#   roster_rows | while IFS=',' read -r SID IID IP PORT KEY; do ...; done
roster_rows() {
  [ -f "$KALI_ROSTER" ] || { echo "No $KALI_ROSTER -- run kali_fleet/provision_students.sh first." >&2; return 1; }
  tail -n +2 "$KALI_ROSTER" | grep -v '^[[:space:]]*$'
}
