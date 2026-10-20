#!/usr/bin/env bash
# Terminates every Kali VM tagged Project=<PROJECT>-kali and releases their
# Elastic IPs. Optionally also deletes per-student security groups and key
# pairs, the daily schedules, and the scheduler IAM role.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"
ROLE_NAME="${PROJECT}-kali-scheduler-role"

IDS="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Project,Values=$KALI_TAG" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
if [ -z "$IDS" ]; then
  echo "No $KALI_TAG instances found."
else
  echo "== Terminating: $IDS =="
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --region "$REGION" --instance-ids $IDS >/dev/null
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $IDS
fi

# Always release EIPs -- an unattached Elastic IP still bills hourly.
for aid in $(aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=tag:Project,Values=$KALI_TAG" --query 'Addresses[].AllocationId' --output text); do
  aws ec2 release-address --region "$REGION" --allocation-id "$aid" \
    || echo "   couldn't release $aid yet -- re-run in a minute"
done

read -rp "Also delete security groups, key pairs, daily schedules and the scheduler role? [y/N] " CONFIRM
case "$CONFIRM" in
  [Yy]*) ;;
  *) echo "== Instances terminated, EIPs released; everything else kept. =="; exit 0 ;;
esac

# Find per-student resources by name prefix rather than students.csv, so
# students removed from the CSV mid-term are cleaned up too.
for sg in $(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=${KALI_TAG}-*-sg" --query 'SecurityGroups[].GroupId' --output text); do
  aws ec2 delete-security-group --region "$REGION" --group-id "$sg" \
    || echo "   $sg still in use -- re-run in a minute"
done
for kp in $(aws ec2 describe-key-pairs --region "$REGION" \
    --filters "Name=key-name,Values=${KALI_TAG}-*" --query 'KeyPairs[].KeyName' --output text); do
  aws ec2 delete-key-pair --region "$REGION" --key-name "$kp" >/dev/null
done
rm -f "$HERE"/student_keys/*.pem "$KALI_ROSTER" "$HERE/distribution_checklist.md"

for s in "${KALI_TAG}-daily-start" "${KALI_TAG}-daily-stop"; do
  aws scheduler delete-schedule --region "$REGION" --name "$s" 2>/dev/null || true
done
aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "start-stop-${KALI_TAG}-only" 2>/dev/null || true
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
echo "== Full teardown complete. =="
