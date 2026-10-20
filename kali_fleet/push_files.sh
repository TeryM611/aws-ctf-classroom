#!/usr/bin/env bash
# Copies a local folder of lab files onto EVERY student's Kali VM, for weeks
# with no server (crypto, forensics, reversing binaries...).
#
#   ./push_files.sh <local_dir> [remote_dir]
#   ./push_files.sh ../week09/lab week09         # -> ~/week09/ on every VM
#
# Re-run safe: files that already exist on a VM are never overwritten, so
# students' notes and edits survive. (That also means a corrected file won't
# replace an old copy -- delete it on the VMs first if you need to.)
#
# Keep answer keys, solvers and instructor notes OUT of <local_dir>.
# EXCLUDES skips matching names, e.g. to keep instructions in your LMS instead:
#   EXCLUDES="README.md *.key" ./push_files.sh ../week09/lab week09
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

SRC="${1:?usage: $0 <local_dir> [remote_dir]}"
[ -d "$SRC" ] || { echo "Not a directory: $SRC" >&2; exit 1; }
SRC="$(cd "$SRC" && pwd)"
DEST="${2:-$(basename "$SRC")}"
case "$DEST" in /*|*..*) echo "remote_dir must be relative to the VM's home folder." >&2; exit 1 ;; esac

EXCL=(--exclude .DS_Store)
for pat in ${EXCLUDES:-}; do EXCL+=(--exclude "$pat"); done

BUNDLE="$(mktemp)"
trap 'rm -f "$BUNDLE"' EXIT
COPYFILE_DISABLE=1 tar czf "$BUNDLE" --no-xattrs "${EXCL[@]}" -C "$SRC" .
echo "== Pushing $SRC -> ~/$DEST/ on every VM =="

OK=0; FAIL=0
while IFS=',' read -r SID IID IP PORT KEY || [ -n "$SID" ]; do
  [ -z "$SID" ] && continue
  printf '   %s (%s) ' "$SID" "$IP"
  # ssh's stdin is the bundle, not the loop's input, so the loop is safe.
  if ssh "${SSH_OPTS[@]}" -i "$KEY" -p "$PORT" "kali@$IP" \
      "mkdir -p ~/'$DEST' && tar xzf - -C ~/'$DEST' --skip-old-files" < "$BUNDLE"; then
    echo ok; OK=$((OK+1))
  else
    echo "FAILED (VM stopped, or still booting?)"; FAIL=$((FAIL+1))
  fi
done < <(roster_rows)
echo "== $OK ok, $FAIL failed =="
