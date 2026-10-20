#!/usr/bin/env bash
# Deploys the shared target server: one EC2 instance running every app in
# apps/ via Docker Compose. Run from any machine with the AWS CLI configured
# (your laptop or AWS CloudShell).
#
# Creates:
#   - a private S3 bucket, only to stage the app bundle onto the instance
#   - a key pair for your own SSH access (saved to target/keys/)
#   - a security group: SSH (22) and the app ports open ONLY to your current
#     IP. Students are added later by IP via roster.csv + sync_roster.sh --
#     never 0.0.0.0/0.
#   - the instance itself, with:
#       * NO IAM instance profile: even if an intentionally vulnerable app
#         gets a shell, there are no AWS credentials on the box to steal
#       * IMDSv2 required + hop limit 1, so containers can't reach the
#         instance metadata service at all
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

KEY_NAME="${PROJECT}-target"
SG_NAME="${PROJECT}-target-sg"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${BUCKET:-${PROJECT}-bundle-${ACCOUNT_ID}}"
S3_KEY="bundle.tar.gz"
mkdir -p "$HERE/keys"

echo "== Region: $REGION | Instance type: $TARGET_INSTANCE_TYPE | Ports: $APP_PORTS =="

# ---- bundle apps/ + deploy/ ----
BUNDLE="$(mktemp)"
trap 'rm -f "$BUNDLE" "${USERDATA:-}"' EXIT
COPYFILE_DISABLE=1 tar czf "$BUNDLE" --no-xattrs --exclude .DS_Store -C "$HERE" apps deploy

MY_IP="$(curl -s https://checkip.amazonaws.com)"
echo "== Your public IP (SSH + your own test access): $MY_IP =="

# ---- S3 staging bucket ----
if ! aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "== Creating staging bucket $BUCKET =="
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi
aws s3 cp "$BUNDLE" "s3://$BUCKET/$S3_KEY" --region "$REGION" >/dev/null
# The instance has no IAM role (by design), so it fetches the bundle with a
# plain curl against a short-lived presigned URL instead of `aws s3 cp`.
BUNDLE_URL="$(aws s3 presign "s3://$BUCKET/$S3_KEY" --region "$REGION" --expires-in 3600)"

# ---- key pair ----
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "== Creating key pair $KEY_NAME -> target/keys/$KEY_NAME.pem =="
  aws ec2 create-key-pair --key-name "$KEY_NAME" --region "$REGION" \
    --query 'KeyMaterial' --output text > "$HERE/keys/$KEY_NAME.pem"
  chmod 400 "$HERE/keys/$KEY_NAME.pem"
fi

# ---- security group in the default VPC ----
VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)"
[ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ] || { echo "ERROR: no default VPC in $REGION." >&2; exit 1; }

SG_ID="$(aws ec2 describe-security-groups --region "$REGION" \
  --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
  SG_ID="$(aws ec2 create-security-group --region "$REGION" --group-name "$SG_NAME" \
    --description "CTF target -- app ports allow-listed per IP only" \
    --vpc-id "$VPC_ID" --query 'GroupId' --output text)"
fi
for PORT in 22 $APP_PORTS; do
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
    --protocol tcp --port "$PORT" --cidr "${MY_IP}/32" >/dev/null 2>&1 || true
done
# You are "student zero" in the roster, so sync_roster.sh never revokes you.
[ -f "$HERE/roster.csv" ] || cp "$HERE/roster.csv.example" "$HERE/roster.csv"
grep -v '^instructor,' "$HERE/roster.csv" > "$HERE/roster.csv.tmp" || true
echo "instructor,$MY_IP" >> "$HERE/roster.csv.tmp"
mv "$HERE/roster.csv.tmp" "$HERE/roster.csv"

# ---- AMI: latest Ubuntu 22.04 LTS from Canonical's public SSM parameter ----
AMI_ID="$(aws ssm get-parameters --region "$REGION" \
  --names /aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id \
  --query 'Parameters[0].Value' --output text)"

# ---- user-data ----
USERDATA="$(mktemp)"
cat > "$USERDATA" <<EOF
#!/bin/bash
exec > >(tee /var/log/user-data.log) 2>&1
set -x
apt-get update -y
curl -fsSL https://get.docker.com | sh
apt-get install -y docker-compose-plugin
mkdir -p /opt/ctf
curl -fsSL "${BUNDLE_URL}" -o /opt/ctf/bundle.tar.gz
tar xzf /opt/ctf/bundle.tar.gz -C /opt/ctf
cd /opt/ctf
# Build images ONE AT A TIME. Compose builds in parallel by default, which
# exhausted a t3.micro's 1GB RAM and wedged the instance so badly that EC2's
# own reachability check failed.
for svc in \$(docker compose -f deploy/docker-compose.yml config --services); do
  docker compose -f deploy/docker-compose.yml build "\$svc"
done
docker compose -f deploy/docker-compose.yml up -d
echo "USER-DATA DONE"
EOF

echo "== Launching instance =="
INSTANCE_ID="$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI_ID" --instance-type "$TARGET_INSTANCE_TYPE" \
  --key-name "$KEY_NAME" --security-group-ids "$SG_ID" \
  --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled" \
  --user-data "file://$USERDATA" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT}-target},{Key=Project,Value=${PROJECT}-target}]" \
  --query 'Instances[0].InstanceId' --output text)"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
PUBLIC_IP="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

echo "$INSTANCE_ID" > "$HERE/.instance_id"
echo "$SG_ID" > "$HERE/.sg_id"
echo "$BUCKET" > "$HERE/.bucket"

echo
echo "Instance $INSTANCE_ID is up at $PUBLIC_IP."
echo "Docker setup takes a few minutes after boot. Then:"
echo "  ./check_status.sh"
for PORT in $APP_PORTS; do echo "  http://$PUBLIC_IP:$PORT"; done
echo
echo "Add students by IP: edit roster.csv, then ./sync_roster.sh"
echo "(or ./link_kali_to_target.sh first, if they attack from the Kali fleet)."
echo "When done: ./teardown_target.sh"
