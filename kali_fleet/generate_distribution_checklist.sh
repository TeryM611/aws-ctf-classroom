#!/usr/bin/env bash
# Writes distribution_checklist.md: one checkbox per student with the exact
# key file to attach and a ready-to-paste message containing their own SSH
# command. Send each one as a PRIVATE message through your LMS (Canvas Inbox,
# Moodle messages, ...) -- never post keys in a shared place.
#
# Searching the student ID in the LMS's "To:" field doubles as a safety
# check: if the name that autocompletes doesn't match, stop before sending.
#
# Optional: COURSE_URL="https://your.lms/courses/123" ./generate_distribution_checklist.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"
OUT="$HERE/distribution_checklist.md"

{
  echo "# Kali VM key distribution checklist"
  echo
  [ -n "${COURSE_URL:-}" ] && { echo "Course: $COURSE_URL"; echo; }
  echo "For each student: compose a private message, search their ID in **To:**,"
  echo "confirm the name matches, paste the subject and body, attach the file, send."
  echo
  N=0
  while IFS=',' read -r SID IID IP PORT KEY || [ -n "$SID" ]; do
    [ -z "$SID" ] && continue
    N=$((N+1))
    cat <<EOF
---

## [ ] $N. \`$SID\`

- **Attach:** \`$KEY\`
- **Subject:** \`Your Kali VM access\`
- **Body:**

\`\`\`
Hi,

Attached is your personal SSH key for the course's Kali VM. It is yours
alone -- don't share it or forward this message.

1. Save the attached file somewhere safe.
2. Mac/Linux: chmod 400 <the saved file>
   Windows (PowerShell), only if you get "permissions are too open":
     icacls.exe <the saved file> /inheritance:r
     icacls.exe <the saved file> /grant:r "\$env:username:R"
3. Connect:
     ssh -p $PORT -i <the saved file> kali@$IP
   (Windows 10/11 has ssh built in, in PowerShell or Command Prompt.)

The VM runs daily from ${START_HOUR}:00 to ${STOP_HOUR}:00 (24-hour clock,
$TIMEZONE) and is powered off outside that window. No AWS account is
needed on your end.
\`\`\`

EOF
  done < <(roster_rows)
} > "$OUT"
echo "== Wrote $OUT ($(roster_rows | wc -l | tr -d ' ') students) =="
