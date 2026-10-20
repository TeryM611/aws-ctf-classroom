#!/usr/bin/env bash
# Makes the target's security group match roster.csv EXACTLY on every app
# port: adds IPs in the file that aren't allowed yet, and revokes allowed IPs
# that are no longer in the file (so removing a row really removes access).
#
# roster.csv: one `name,ip` per line; the IP is always taken as the LAST
# field. Blank lines and # comments are ignored.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"
ROSTER="$HERE/roster.csv"

[ -f "$HERE/.sg_id" ] || { echo "No .sg_id -- run deploy_target.sh first." >&2; exit 1; }
[ -f "$ROSTER" ] || { echo "No roster.csv -- copy roster.csv.example." >&2; exit 1; }
SG_ID="$(cat "$HERE/.sg_id")"
strip_bom "$ROSTER"

DESIRED="$(grep -v '^[[:space:]]*#' "$ROSTER" | grep -v '^[[:space:]]*$' \
  | awk -F',' '{print $NF}' | tr -d ' \r"' | sort -u || true)"
echo "== Roster has $(printf '%s\n' "$DESIRED" | grep -c . || true) IP(s) =="

for PORT in $APP_PORTS; do
  echo "-- port $PORT --"
  CURRENT="$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$SG_ID" \
    --query "SecurityGroups[0].IpPermissions[?ToPort==\`$PORT\`].IpRanges[].CidrIp" --output text \
    | tr '\t' '\n' | sed 's#/32$##' | grep -v '^$' | grep -vx None || true)"

  for ip in $DESIRED; do
    if ! printf '%s\n' "$CURRENT" | grep -qx "$ip"; then
      echo "   + allow $ip"
      aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
        --protocol tcp --port "$PORT" --cidr "${ip}/32" >/dev/null
    fi
  done
  for ip in $CURRENT; do
    if ! printf '%s\n' "$DESIRED" | grep -qx "$ip"; then
      echo "   - revoke $ip"
      aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
        --protocol tcp --port "$PORT" --cidr "${ip}/32" >/dev/null
    fi
  done
done
echo "== Security group $SG_ID now matches roster.csv on ports: $APP_PORTS =="
