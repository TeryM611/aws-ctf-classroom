#!/usr/bin/env bash
# Daily wake/sleep window for the whole Kali fleet: start at START_HOUR, stop
# at STOP_HOUR, every day in TIMEZONE (all from config.env). With Elastic
# IPs, each VM keeps its address across the stop/start.
#
# Uses EventBridge Scheduler calling the EC2 API directly -- no Lambda. Its
# IAM role can ONLY start/stop instances tagged Project=<PROJECT>-kali.
#
# Schedules target a fixed list of instance IDs, so re-run this after
# provisioning more students.
#
# Deliberately NOT included: an idle-CPU auto-stop alarm. It was tried and
# removed -- it put VMs to sleep in the middle of office hours and labs, and
# the resulting "SSH times out" reports cost more than the compute it saved.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"
ROLE_NAME="${PROJECT}-kali-scheduler-role"
POLICY_NAME="start-stop-${KALI_TAG}-only"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
INSTANCE_IDS_JSON="$(roster_rows | cut -d',' -f2 | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().split()))')"
echo "== Scheduling $(python3 -c 'import sys,json; print(len(json.loads(sys.argv[1])))' "$INSTANCE_IDS_JSON") instance(s) =="

if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "== Creating IAM role $ROLE_NAME =="
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Principal": {"Service": "scheduler.amazonaws.com"}, "Action": "sts:AssumeRole"}]
  }' >/dev/null
  aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "$POLICY_NAME" --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [\"ec2:StartInstances\", \"ec2:StopInstances\"],
      \"Resource\": \"*\",
      \"Condition\": {\"StringEquals\": {\"aws:ResourceTag/Project\": \"$KALI_TAG\"}}
    }]
  }" >/dev/null
  echo "   waiting for IAM propagation..."
  sleep 10
fi
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

upsert_schedule() {
  local name="$1" cron="$2" api="$3" target action
  # Target.Input must be a JSON *string* containing the API payload (double
  # encoded). Built in Python because hand-quoting this in bash broke twice.
  target="$(API="$api" ROLE_ARN="$ROLE_ARN" IDS="$INSTANCE_IDS_JSON" python3 -c '
import json, os
print(json.dumps({
    "Arn": "arn:aws:scheduler:::aws-sdk:ec2:" + os.environ["API"],
    "RoleArn": os.environ["ROLE_ARN"],
    "Input": json.dumps({"InstanceIds": json.loads(os.environ["IDS"])}),
}))')"
  if aws scheduler get-schedule --region "$REGION" --name "$name" >/dev/null 2>&1; then
    action=update-schedule
  else
    action=create-schedule
  fi
  aws scheduler "$action" --region "$REGION" --name "$name" \
    --schedule-expression "$cron" --schedule-expression-timezone "$TIMEZONE" \
    --flexible-time-window '{"Mode": "OFF"}' --target "$target" >/dev/null
  echo "   $action: $name ($cron $TIMEZONE)"
}

upsert_schedule "${KALI_TAG}-daily-start" "cron(0 $START_HOUR * * ? *)" "startInstances"
upsert_schedule "${KALI_TAG}-daily-stop"  "cron(0 $STOP_HOUR * * ? *)"  "stopInstances"
echo "== Done: VMs run from ${START_HOUR}:00 to ${STOP_HOUR}:00, $TIMEZONE =="
