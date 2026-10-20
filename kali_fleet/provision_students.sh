#!/usr/bin/env bash
# Provisions one isolated Kali VM PER STUDENT from students.csv (one student
# ID per line). Idempotent: students who already have an instance (in any
# state, including stopped) are skipped, so add rows and re-run freely.
#
# Per student:
#   - its own key pair: THE access control. The Kali AMI allows public-key
#     SSH only (password and keyboard-interactive login are disabled), so
#     SSH can be open to any source IP and students connect from anywhere
#     without you tracking their IPs. Whoever holds the .pem gets in.
#   - its own security group, so one student can be cut off without
#     touching anyone else
#   - NO IAM instance profile: a student with root on their VM still has
#     zero access to your AWS account
#   - an Elastic IP, so the address survives the daily stop/start
#   - sshd moved to $SSH_PORT and the toolset from config.env installed at
#     first boot
#
# Requires a one-time, free AWS Marketplace subscription to the official Kali
# AMI -- see README.md. This script checks for it before launching anything.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"
STUDENTS="$HERE/students.csv"
KEYDIR="$HERE/student_keys"
[ -f "$STUDENTS" ] || { echo "No students.csv -- copy students.csv.example and fill it in." >&2; exit 1; }
mkdir -p "$KEYDIR"

# ---- AMI: newest official Kali image (publisher account 679593333241) ----
if [ -z "$KALI_AMI" ]; then
  KALI_AMI="$(aws ec2 describe-images --region "$REGION" --owners 679593333241 \
    --filters "Name=name,Values=*kali-last-snapshot-amd64-*" \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)"
  [ -n "$KALI_AMI" ] && [ "$KALI_AMI" != "None" ] || { echo "No official Kali AMI found in $REGION." >&2; exit 1; }
fi
echo "== Kali AMI: $KALI_AMI | type: $KALI_INSTANCE_TYPE | region: $REGION =="

# ---- preflight: Marketplace subscription ----
PRE="$(aws ec2 run-instances --dry-run --region "$REGION" --image-id "$KALI_AMI" \
  --instance-type "$KALI_INSTANCE_TYPE" 2>&1 || true)"
case "$PRE" in
  *DryRunOperation*) ;;
  *OptInRequired*)
    echo "Kali AMI not subscribed yet. Subscribe (free) first -- see README.md, then re-run." >&2; exit 1 ;;
  *) echo "Preflight failed: $PRE" >&2; exit 1 ;;
esac

VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)"
[ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ] || { echo "ERROR: no default VPC in $REGION." >&2; exit 1; }

# ---- first-boot script, same for every student ----
USERDATA="$(mktemp)"
trap 'rm -f "$USERDATA"' EXIT
{
  echo '#!/bin/bash'
  echo 'exec > >(tee /var/log/kali-provision.log) 2>&1'
  echo "echo 'Port $SSH_PORT' > /etc/ssh/sshd_config.d/99-custom-port.conf"
  echo 'systemctl restart ssh'
  echo 'apt-get update -y'
  echo "DEBIAN_FRONTEND=noninteractive apt-get install -y $KALI_PACKAGES"
  if [ -n "$PIP_PACKAGES" ]; then
    echo "sudo -u kali pip3 install --break-system-packages --quiet $PIP_PACKAGES"
    # pip puts CLI tools (e.g. pwntools' cyclic, checksec) in ~/.local/bin,
    # which isn't on PATH. The AMI's default shell is zsh, so fix both rc files.
    cat <<'EOF'
for rc in /home/kali/.zshrc /home/kali/.bashrc; do
  grep -q '.local/bin' "$rc" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
  chown kali:kali "$rc"
done
EOF
  fi
  echo 'echo "KALI-PROVISION DONE"'
} > "$USERDATA"

echo "student_id,instance_id,public_ip,ssh_port,key_file" > "$KALI_ROSTER"

for SID in $(student_ids "$STUDENTS"); do
  NAME="${KALI_TAG}-${SID}"
  echo "== $SID =="

  # Match stopped instances too -- otherwise a re-run outside the daily
  # window would launch a duplicate for every sleeping VM.
  INSTANCE_ID="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)"

  if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
    echo "   already provisioned: $INSTANCE_ID"
  else
    if ! aws ec2 describe-key-pairs --region "$REGION" --key-names "$NAME" >/dev/null 2>&1; then
      aws ec2 create-key-pair --region "$REGION" --key-name "$NAME" \
        --query 'KeyMaterial' --output text > "$KEYDIR/$SID.pem"
      chmod 400 "$KEYDIR/$SID.pem"
    fi
    # AWS only hands out a private key once, at creation.
    [ -f "$KEYDIR/$SID.pem" ] || echo "   WARNING: key pair $NAME exists in AWS but $KEYDIR/$SID.pem is missing." \
      "Delete it (aws ec2 delete-key-pair --key-name $NAME) and re-run to issue a new key."

    SG_ID="$(aws ec2 describe-security-groups --region "$REGION" \
      --filters Name=group-name,Values="${NAME}-sg" Name=vpc-id,Values="$VPC_ID" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
    if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
      SG_ID="$(aws ec2 create-security-group --region "$REGION" --group-name "${NAME}-sg" \
        --description "Kali VM for $SID -- pubkey-only SSH" \
        --vpc-id "$VPC_ID" --query 'GroupId' --output text)"
    fi
    aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
      --protocol tcp --port "$SSH_PORT" --cidr 0.0.0.0/0 >/dev/null 2>&1 || true

    INSTANCE_ID="$(aws ec2 run-instances --region "$REGION" \
      --image-id "$KALI_AMI" --instance-type "$KALI_INSTANCE_TYPE" \
      --key-name "$NAME" --security-group-ids "$SG_ID" \
      --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1" \
      --user-data "file://$USERDATA" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=Project,Value=$KALI_TAG},{Key=Student,Value=$SID}]" \
      --query 'Instances[0].InstanceId' --output text)"
    echo "   launched $INSTANCE_ID, waiting for running..."
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
  fi

  # Elastic IP: a normal public IP changes on every stop/start.
  EIP="$(aws ec2 describe-addresses --region "$REGION" --filters "Name=instance-id,Values=$INSTANCE_ID" \
    --query 'Addresses[0].PublicIp' --output text 2>/dev/null || true)"
  if [ -z "$EIP" ] || [ "$EIP" = "None" ]; then
    # Reuse this student's address if their old VM was terminated and rebuilt,
    # so their ssh command doesn't change (and the old EIP doesn't sit billing).
    ALLOC_ID="$(aws ec2 describe-addresses --region "$REGION" \
      --filters "Name=tag:Project,Values=$KALI_TAG" "Name=tag:Student,Values=$SID" \
      --query 'Addresses[?AssociationId==null] | [0].AllocationId' --output text 2>/dev/null || true)"
    if [ -z "$ALLOC_ID" ] || [ "$ALLOC_ID" = "None" ]; then
      ALLOC_ID="$(aws ec2 allocate-address --region "$REGION" --domain vpc \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$NAME-eip},{Key=Project,Value=$KALI_TAG},{Key=Student,Value=$SID}]" \
        --query 'AllocationId' --output text)"
    fi
    aws ec2 associate-address --region "$REGION" --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC_ID" >/dev/null
    EIP="$(aws ec2 describe-addresses --region "$REGION" --allocation-ids "$ALLOC_ID" --query 'Addresses[0].PublicIp' --output text)"
  fi
  echo "   $INSTANCE_ID -> $EIP"
  echo "$SID,$INSTANCE_ID,$EIP,$SSH_PORT,$KEYDIR/$SID.pem" >> "$KALI_ROSTER"
done

cat <<EOF

== Done. Connection info per student: $KALI_ROSTER ==
First boot installs the toolset; allow ~10-15 min before students log in.
Students connect with: ssh -p $SSH_PORT -i <their .pem> kali@<their IP>

Next:
  ./setup_daily_schedule.sh            # daily start/stop window (re-run after adding students)
  ./generate_distribution_checklist.sh # one private message per student with their key
EOF
