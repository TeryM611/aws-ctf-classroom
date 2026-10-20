#!/usr/bin/env bash
# Health check: instance state, then an HTTP request to every app port (works
# from your machine because you're allow-listed as "instructor").
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"
[ -f "$HERE/.instance_id" ] || { echo "No .instance_id -- run deploy_target.sh first." >&2; exit 1; }
INSTANCE_ID="$(cat "$HERE/.instance_id")"

read -r STATE PUBLIC_IP < <(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress]' --output text)
echo "Instance $INSTANCE_ID: $STATE, public IP $PUBLIC_IP"
for PORT in $APP_PORTS; do
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$PUBLIC_IP:$PORT/" || true)"
  [ "$code" = "000" ] && code="timeout/refused"
  echo "  http://$PUBLIC_IP:$PORT -> $code"
done
cat <<EOF

All timeout/refused? Setup may still be running (give it a few minutes), your
IP may have changed (./update_my_ip.sh), or setup failed. To look:
  ssh -i keys/${PROJECT}-target.pem ubuntu@$PUBLIC_IP
  sudo tail -50 /var/log/user-data.log
  cd /opt/ctf && sudo docker compose -f deploy/docker-compose.yml ps
EOF
