#!/usr/bin/env bash
# Installs KALI_PACKAGES / PIP_PACKAGES (config.env) on VMs that are ALREADY
# running -- for when you add a tool mid-term. New VMs get the same set at
# first boot from provision_students.sh. Re-run safe.
#
# Runs one VM at a time on purpose: a stuck install is easy to spot, and 30
# VMs don't hammer Kali's package mirror at once.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

roster_rows | while IFS=',' read -r SID IID IP PORT KEY || [ -n "$SID" ]; do
  [ -z "$SID" ] && continue
  echo "== $SID ($IP) =="
  # -n is essential: without it, ssh swallows the rest of this loop's input
  # and the script quietly stops after the first student.
  ssh -n "${SSH_OPTS[@]}" -i "$KEY" -p "$PORT" "kali@$IP" "
    set -e
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $KALI_PACKAGES
    if [ -n '$PIP_PACKAGES' ]; then pip3 install --break-system-packages --quiet $PIP_PACKAGES; fi
    for rc in ~/.zshrc ~/.bashrc; do
      grep -q '.local/bin' \"\$rc\" 2>/dev/null || echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> \"\$rc\"
    done
  " && echo "   ok" || echo "   FAILED -- check manually"
done
