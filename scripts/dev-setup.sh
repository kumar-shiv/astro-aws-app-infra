#!/usr/bin/env bash
# =============================================================================
# dev-setup.sh — Astro App dev infrastructure (S3 + EC2 with Ollama)
#
# Usage:
#   ./dev-setup.sh          # create all resources
#   ./dev-setup.sh teardown # destroy EC2 + EIP + SG (S3 and IAM kept)
#   ./dev-setup.sh status   # show current resource IDs and connection commands
#
# Prerequisites:
#   - AWS CLI configured (aws configure)
#   - SSH key pair generated: ssh-keygen -t rsa -b 4096 -f ~/.ssh/astro-dev-key
#
# State is saved to .dev-state in the same directory as this script.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/.dev-state"
KEY_PATH="${HOME}/.ssh/astro-dev-key"
KEY_NAME="astro-dev-key"
REGION="us-east-1"
INSTANCE_TYPE="m7g.2xlarge"  # 8 vCPU / 32 GB — required for gemma4 (9.6 GB) + 16K KV cache without swap
ROOT_VOLUME_GB=30

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[$(date '+%H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

# SSL verification disabled globally via ~/.aws/config (cli_verify_ssl = false)

# Write plain KEY=value pairs — declare -p produces `declare -- VAR=val` which
# creates local variables when sourced inside a function, silently breaking
# teardown/status. Plain assignments survive the source-into-caller scope.
save_state() {
  cat > "${STATE_FILE}" <<EOF
ACCOUNT_ID="${ACCOUNT_ID:-}"
DEFAULT_VPC="${DEFAULT_VPC:-}"
SG_ID="${SG_ID:-}"
INSTANCE_ID="${INSTANCE_ID:-}"
ALLOC_ID="${ALLOC_ID:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
EOF
}

load_state() {
  [[ -f "${STATE_FILE}" ]] || err "No state file found at ${STATE_FILE}. Run setup first."
  # shellcheck source=/dev/null
  source "${STATE_FILE}"
  [[ -n "${INSTANCE_ID:-}" ]] || err "State file is incomplete — INSTANCE_ID missing. Check ${STATE_FILE}."
}

require_aws_cli() {
  command -v aws > /dev/null 2>&1 || err "AWS CLI not found. Install from https://aws.amazon.com/cli/"
  aws sts get-caller-identity > /dev/null 2>&1 || err "AWS CLI not configured. Run: aws configure"
}

require_ssh_key() {
  [[ -f "${KEY_PATH}" ]]     || err "SSH private key not found at ${KEY_PATH}. Run: ssh-keygen -t rsa -b 4096 -f ${KEY_PATH}"
  [[ -f "${KEY_PATH}.pub" ]] || err "SSH public key not found at ${KEY_PATH}.pub"
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

setup() {
  require_aws_cli
  require_ssh_key

  [[ -f "${STATE_FILE}" ]] && err "State file already exists at ${STATE_FILE}. Run teardown first or check 'status'."

  # Initialise all state vars so save_state can be called at any point
  ACCOUNT_ID="" DEFAULT_VPC="" SG_ID="" INSTANCE_ID="" ALLOC_ID="" PUBLIC_IP=""

  # Flush partial state on any exit so orphaned resources are recoverable
  trap 'save_state 2>/dev/null || true' EXIT

  log "Starting dev infrastructure setup..."

  # ── Account ID ─────────────────────────────────────────────────────────────
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  log "Account: ${ACCOUNT_ID}"

  RAW_BUCKET="astro-app-prod-raw-${ACCOUNT_ID}"
  OUTPUT_BUCKET="astro-app-prod-output-${ACCOUNT_ID}"

  # ── S3 Buckets ─────────────────────────────────────────────────────────────
  log "Creating S3 buckets..."
  STATE_BUCKET="astro-app-terraform-state-${ACCOUNT_ID}"
  for bucket in "${RAW_BUCKET}" "${OUTPUT_BUCKET}" "${STATE_BUCKET}"; do
    if aws s3api head-bucket --bucket "${bucket}" --region "${REGION}" 2>/dev/null; then
      log "  ${bucket} already exists — skipping"
    else
      aws s3 mb "s3://${bucket}" --region "${REGION}"
      log "  created ${bucket}"
    fi
  done

  aws s3api put-bucket-versioning --bucket "${RAW_BUCKET}"    --versioning-configuration Status=Enabled
  aws s3api put-bucket-versioning --bucket "${OUTPUT_BUCKET}" --versioning-configuration Status=Enabled
  log "Versioning enabled on data buckets"

  # ── IAM Role ───────────────────────────────────────────────────────────────
  log "Creating IAM role..."
  if ! aws iam get-role --role-name astro-app-dev-ec2-role > /dev/null 2>&1; then
    aws iam create-role \
      --role-name astro-app-dev-ec2-role \
      --assume-role-policy-document '{
        "Version":"2012-10-17",
        "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]
      }' > /dev/null

    aws iam put-role-policy \
      --role-name astro-app-dev-ec2-role \
      --policy-name astro-app-dev-s3 \
      --policy-document "{
        \"Version\":\"2012-10-17\",
        \"Statement\":[
          {\"Effect\":\"Allow\",
           \"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],
           \"Resource\":[\"arn:aws:s3:::${RAW_BUCKET}\",\"arn:aws:s3:::${RAW_BUCKET}/*\"]},
          {\"Effect\":\"Allow\",
           \"Action\":[\"s3:PutObject\",\"s3:GetObject\",\"s3:ListBucket\"],
           \"Resource\":[\"arn:aws:s3:::${OUTPUT_BUCKET}\",\"arn:aws:s3:::${OUTPUT_BUCKET}/*\"]}
        ]
      }"

    aws iam attach-role-policy \
      --role-name astro-app-dev-ec2-role \
      --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

    log "  IAM role created"
  else
    log "  IAM role already exists — skipping"
  fi

  # Instance profile checked independently — role creation may have succeeded
  # on a prior run while profile creation failed
  if ! aws iam get-instance-profile --instance-profile-name astro-app-dev-ec2-profile > /dev/null 2>&1; then
    aws iam create-instance-profile \
      --instance-profile-name astro-app-dev-ec2-profile > /dev/null
    aws iam add-role-to-instance-profile \
      --instance-profile-name astro-app-dev-ec2-profile \
      --role-name astro-app-dev-ec2-role
    log "  Waiting 10 s for IAM propagation..."
    sleep 10
    log "  Instance profile created"
  else
    log "  Instance profile already exists — skipping"
  fi

  # ── SSH Key Pair ────────────────────────────────────────────────────────────
  log "Registering SSH key pair..."
  if aws ec2 describe-key-pairs --key-names "${KEY_NAME}" --region "${REGION}" > /dev/null 2>&1; then
    log "  Key pair '${KEY_NAME}' already exists — skipping"
  else
    aws ec2 import-key-pair \
      --key-name "${KEY_NAME}" \
      --public-key-material "fileb://$(cygpath -m "${KEY_PATH}.pub")" \
      --region "${REGION}" > /dev/null
    log "  Key pair registered"
  fi

  # ── Security Group ──────────────────────────────────────────────────────────
  log "Creating security group..."
  DEFAULT_VPC=$(aws ec2 describe-vpcs \
    --filters Name=isDefault,Values=true \
    --query "Vpcs[0].VpcId" --output text --region "${REGION}")
  [[ "${DEFAULT_VPC}" == "None" || -z "${DEFAULT_VPC}" ]] && \
    err "No default VPC found in ${REGION}. Create one via: aws ec2 create-default-vpc --region ${REGION}"

  EXISTING_SG=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=astro-app-dev-sg" "Name=vpc-id,Values=${DEFAULT_VPC}" \
    --query "SecurityGroups[0].GroupId" --output text --region "${REGION}" 2>/dev/null || echo "None")

  if [[ "${EXISTING_SG}" != "None" && -n "${EXISTING_SG}" ]]; then
    SG_ID="${EXISTING_SG}"
    log "  Security group already exists — reusing ${SG_ID}"
    # Ensure SSH ingress rule exists — may be missing if a prior run failed during IP check
    MY_IP=$(curl -sfk https://checkip.amazonaws.com) || err "Could not determine your public IP. Check network connectivity."
    EXISTING_RULE=$(aws ec2 describe-security-groups \
      --group-ids "${SG_ID}" --region "${REGION}" \
      --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\`].IpRanges[?CidrIp==\`${MY_IP}/32\`].CidrIp" \
      --output text 2>/dev/null || true)
    if [[ -z "${EXISTING_RULE}" ]]; then
      aws ec2 authorize-security-group-ingress \
        --group-id "${SG_ID}" --protocol tcp --port 22 --cidr "${MY_IP}/32" \
        --region "${REGION}" > /dev/null
      log "  SSH rule added for ${MY_IP}/32"
    else
      log "  SSH rule already present for ${MY_IP}/32"
    fi
  else
    SG_ID=$(aws ec2 create-security-group \
      --group-name astro-app-dev-sg \
      --description "Dev EC2: SSH inbound only. Ollama not exposed." \
      --vpc-id "${DEFAULT_VPC}" \
      --region "${REGION}" \
      --query GroupId --output text)

    # Restrict SSH to the developer's current public IP
    MY_IP=$(curl -sfk https://checkip.amazonaws.com) || err "Could not determine your public IP. Check network connectivity."
    aws ec2 authorize-security-group-ingress \
      --group-id "${SG_ID}" \
      --protocol tcp --port 22 --cidr "${MY_IP}/32" \
      --region "${REGION}" > /dev/null
    log "  SSH restricted to ${MY_IP}/32"
  fi
  log "  Security group: ${SG_ID} (VPC: ${DEFAULT_VPC})"
  save_state

  # ── EC2 Instance ────────────────────────────────────────────────────────────
  log "Resolving latest Amazon Linux 2023 ARM64 AMI..."
  AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-*-kernel-*-arm64" \
              "Name=architecture,Values=arm64" \
              "Name=state,Values=available" \
    --query "sort_by(Images,&CreationDate)[-1].ImageId" \
    --output text --region "${REGION}")
  log "  AMI: ${AMI_ID}"

  log "Launching EC2 instance (${INSTANCE_TYPE}, Spot)..."
  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "${AMI_ID}" \
    --instance-type "${INSTANCE_TYPE}" \
    --key-name "${KEY_NAME}" \
    --security-group-ids "${SG_ID}" \
    --iam-instance-profile Name=astro-app-dev-ec2-profile \
    --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${ROOT_VOLUME_GB},\"VolumeType\":\"gp3\",\"Encrypted\":true,\"DeleteOnTermination\":true}}]" \
    --user-data '#!/bin/bash
set -euo pipefail
exec > /var/log/user-data.log 2>&1

echo "=== Installing Ollama ==="
curl -fsSL https://ollama.com/install.sh | sh
systemctl enable ollama && systemctl start ollama

echo "=== Waiting for Ollama to be ready (up to 120s) ==="
READY=false
for i in $(seq 1 24); do
  if curl -sf http://localhost:11434/api/tags > /dev/null; then
    echo "Ollama ready after $((i*5))s"
    READY=true
    break
  fi
  sleep 5
done
if ! ${READY}; then
  echo "ERROR: Ollama did not become ready after 120s"
  exit 1
fi

echo "=== Pulling models (translategemma + gemma4) ==="
export HOME=/root
ollama pull translategemma:latest
ollama pull gemma4:latest

echo "=== Models ready ==="
ollama list' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=astro-app-dev-ec2},{Key=Project,Value=astro-app}]" \
    --region "${REGION}" \
    --query "Instances[0].InstanceId" --output text)

  log "  Instance launched: ${INSTANCE_ID}"
  save_state  # persist instance ID immediately — EIP not yet allocated

  log "  Waiting for instance to be running..."
  aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --region "${REGION}"

  # ── Elastic IP ──────────────────────────────────────────────────────────────
  log "Allocating Elastic IP..."
  ALLOC_ID=$(aws ec2 allocate-address \
    --domain vpc --region "${REGION}" \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=astro-app-dev-eip}]" \
    --query AllocationId --output text)
  save_state  # persist EIP allocation ID before association

  aws ec2 associate-address \
    --instance-id "${INSTANCE_ID}" \
    --allocation-id "${ALLOC_ID}" \
    --region "${REGION}" > /dev/null

  PUBLIC_IP=$(aws ec2 describe-addresses \
    --allocation-ids "${ALLOC_ID}" \
    --query "Addresses[0].PublicIp" --output text --region "${REGION}")

  save_state  # final complete state

  # Trap no longer needed — clean exit from here
  trap - EXIT

  print_summary
}

# ---------------------------------------------------------------------------
# Teardown (EC2 + EIP + SG — S3 and IAM are kept)
# ---------------------------------------------------------------------------

teardown() {
  load_state

  log "Tearing down EC2 resources (S3 and IAM kept)..."

  log "  Terminating instance ${INSTANCE_ID}..."
  aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}" --region "${REGION}" > /dev/null
  aws ec2 wait instance-terminated --instance-ids "${INSTANCE_ID}" --region "${REGION}"
  log "  Instance terminated"

  if [[ -n "${ALLOC_ID:-}" ]]; then
    log "  Releasing Elastic IP ${ALLOC_ID}..."
    aws ec2 release-address --allocation-id "${ALLOC_ID}" --region "${REGION}" 2>/dev/null || \
      log "  EIP ${ALLOC_ID} already released or not found — skipping"
  fi

  if [[ -n "${SG_ID:-}" ]]; then
    log "  Deleting security group ${SG_ID}..."
    aws ec2 delete-security-group --group-id "${SG_ID}" --region "${REGION}" 2>/dev/null || \
      log "  SG ${SG_ID} already deleted or not found — skipping"
  fi

  rm -f "${STATE_FILE}"
  log "Done. State file removed."
  log "S3 buckets and IAM role are preserved. Delete manually if no longer needed."
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

status() {
  load_state
  print_summary
}

print_summary() {
  echo ""
  echo "════════════════════════════════════════════════════════"
  echo "  Dev infrastructure ready"
  echo "════════════════════════════════════════════════════════"
  echo ""
  echo "  Instance:      ${INSTANCE_ID}"
  echo "  Public IP:     ${PUBLIC_IP}  (stable across stop/start)"
  echo "  Raw bucket:    astro-app-prod-raw-${ACCOUNT_ID}"
  echo "  Output bucket: astro-app-prod-output-${ACCOUNT_ID}"
  echo ""
  echo "── Connect ────────────────────────────────────────────"
  echo "  ssh -i ${KEY_PATH} ec2-user@${PUBLIC_IP}"
  echo ""
  echo "── SSH tunnel (run before invoking Python scripts) ────"
  echo "  ssh -N -L 11434:localhost:11434 -i ${KEY_PATH} ec2-user@${PUBLIC_IP}"
  echo ""
  echo "── Check model download progress ──────────────────────"
  echo "  ssh -i ${KEY_PATH} ec2-user@${PUBLIC_IP} 'tail -f /var/log/user-data.log'"
  echo ""
  echo "── Confirm model is ready ───────────────────────────────"
  echo "  ssh -i ${KEY_PATH} ec2-user@${PUBLIC_IP} 'ollama list'"
  echo ""
  echo "── Python invocation (tunnel must be open) ─────────────"
  echo "  PYTHONUTF8=1 \\"
  echo "    LLM_PROVIDER=ollama \\"
  echo "    OLLAMA_BASE_URL=http://localhost:11434 \\"
  echo "    OLLAMA_MODEL=gemma4:latest \\"
  echo "    OLLAMA_TRANSLATE_MODEL=translategemma:latest \\"
  echo "    S3_INPUT_BUCKET=astro-app-prod-raw-${ACCOUNT_ID} \\"
  echo "    S3_OUTPUT_BUCKET=astro-app-prod-output-${ACCOUNT_ID} \\"
  echo "    python3 -m source.corpus.sourceaggregation.qna_transcript_processor --video-id <ID>"
  echo ""
  echo "── Livealone batch convert (all raw → JSONL) ───────────"
  echo "  PYTHONUTF8=1 \\"
  echo "    LLM_PROVIDER=ollama \\"
  echo "    OLLAMA_BASE_URL=http://localhost:11434 \\"
  echo "    OLLAMA_MODEL=gemma4:latest \\"
  echo "    OLLAMA_TRANSLATE_MODEL=translategemma:latest \\"
  echo "    python3 -m source.corpus.sourceaggregation.livealone_batch_converter"
  echo "  # --dry-run   list pending without calling LLM"
  echo "  # --status    show full progress table"
  echo ""
  echo "── Stop EC2 (keeps EIP and data; EIP costs ~\$0.005/hr while stopped) ──"
  echo "  aws ec2 stop-instances --instance-ids ${INSTANCE_ID} --region ${REGION}"
  echo ""
  echo "── Start EC2 ───────────────────────────────────────────"
  echo "  aws ec2 start-instances --instance-ids ${INSTANCE_ID} --region ${REGION}"
  echo ""
  echo "── Teardown ────────────────────────────────────────────"
  echo "  ./dev-setup.sh teardown"
  echo "════════════════════════════════════════════════════════"
  echo ""
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

case "${1:-setup}" in
  setup)    setup ;;
  teardown) teardown ;;
  status)   status ;;
  *)        echo "Usage: $0 [setup|teardown|status]"; exit 1 ;;
esac
