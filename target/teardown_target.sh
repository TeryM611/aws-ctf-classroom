#!/usr/bin/env bash
# Terminates the target instance and, optionally, its security group, key
# pair and staging bucket. These are intentionally vulnerable apps -- don't
# leave them up longer than the lab window needs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"
KEY_NAME="${PROJECT}-target"

if [ -f "$HERE/.instance_id" ]; then
  INSTANCE_ID="$(cat "$HERE/.instance_id")"
  echo "== Terminating $INSTANCE_ID =="
  aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID"
  rm -f "$HERE/.instance_id"
else
  echo "No .instance_id -- skipping instance."
fi

read -rp "Also delete the security group, key pair and S3 staging bucket? [y/N] " CONFIRM
case "$CONFIRM" in
  [Yy]*)
    if [ -f "$HERE/.sg_id" ]; then
      aws ec2 delete-security-group --region "$REGION" --group-id "$(cat "$HERE/.sg_id")" \
        && rm -f "$HERE/.sg_id" \
        || echo "   SG still in use -- AWS can lag after termination; re-run in a minute."
    fi
    aws ec2 delete-key-pair --region "$REGION" --key-name "$KEY_NAME" >/dev/null 2>&1 || true
    rm -f "$HERE/keys/$KEY_NAME.pem"
    if [ -f "$HERE/.bucket" ]; then
      BUCKET="$(cat "$HERE/.bucket")"
      aws s3 rm "s3://$BUCKET" --recursive >/dev/null 2>&1 || true
      aws s3api delete-bucket --region "$REGION" --bucket "$BUCKET" 2>/dev/null && rm -f "$HERE/.bucket" || true
    fi
    echo "== Full teardown complete. ==" ;;
  *) echo "== Instance terminated; SG/key/bucket kept for next time. ==" ;;
esac
