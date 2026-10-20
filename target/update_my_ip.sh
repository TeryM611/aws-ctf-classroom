#!/usr/bin/env bash
# Your own public IP changes (new network, new CloudShell session). This swaps
# your "instructor" row in roster.csv and your SSH + app-port rules to your
# current IP.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"
[ -f "$HERE/.sg_id" ] || { echo "No .sg_id -- run deploy_target.sh first." >&2; exit 1; }
SG_ID="$(cat "$HERE/.sg_id")"

NEW_IP="$(curl -s https://checkip.amazonaws.com)"
OLD_IP="$(grep '^instructor,' "$HERE/roster.csv" 2>/dev/null | tail -1 | cut -d',' -f2 || true)"
echo "New IP: $NEW_IP (was: ${OLD_IP:-none on file})"

if [ -n "$OLD_IP" ] && [ "$OLD_IP" != "$NEW_IP" ]; then
  for PORT in 22 $APP_PORTS; do
    aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
      --protocol tcp --port "$PORT" --cidr "${OLD_IP}/32" >/dev/null 2>&1 || true
  done
fi
for PORT in 22 $APP_PORTS; do
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
    --protocol tcp --port "$PORT" --cidr "${NEW_IP}/32" >/dev/null 2>&1 || true
done

grep -v '^instructor,' "$HERE/roster.csv" > "$HERE/roster.csv.tmp" 2>/dev/null || true
echo "instructor,$NEW_IP" >> "$HERE/roster.csv.tmp"
mv "$HERE/roster.csv.tmp" "$HERE/roster.csv"
echo "Done -- your SSH and app-port access now point at $NEW_IP."
