#!/usr/bin/env bash
# =============================================================================
# mobile-review-setup.sh — Integration environment (App Runner + shared RDS)
#
# Subcommands:
#   setup          create all resources
#   teardown       remove all resources (staging-aware for shared RDS/bastion)
#   status         show service URL and current status
#   deploy         build web/ locally and push to team URL
#   bastion-start  start the shared bastion EC2
#   bastion-stop   stop the shared bastion EC2
#   db-init        print SSM tunnel + db_init.sh commands to initialise schema
#   load-data      print SSM tunnel + load_db.py instructions for corpus loading
#
# Prerequisites:
#   - AWS CLI configured (aws configure)
#   - Docker Desktop running
#
# Shared resources (astrodb-shared RDS, bastion, SGs, subnet group) are NOT
# destroyed during teardown if the staging App Runner service is still live.
# Run staging_setup.sh teardown first in that case.
#
# State is saved to .mobile-review-state — contains DB credentials, never commit.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../" && pwd)"
STATE_FILE="${SCRIPT_DIR}/.mobile-review-state"
REGION="us-east-1"
LOCAL_DB_TUNNEL_PORT=5555

# ── App Runner / ECR (environment-specific) ───────────────────────────────────
ECR_REPO_NAME="astro-webapp"
SERVICE_NAME="astro-webapp-mobile-review"
APP_RUNNER_ECR_ROLE_NAME="astro-app-apprunner-ecr-role"   # shared with staging
CI_USER_NAME="astro-app-mobile-review-ci"
IMAGE_TAG="mobile-review"

# ── Shared DB infrastructure ──────────────────────────────────────────────────
DB_INSTANCE_ID="astrodb-shared"
DB_NAME="astrodb_integration"
DB_USER="astroweb"                                         # RDS master user
DB_SUBNET_GROUP="astrodb-shared-subnet-group"
CONNECTOR_SG_NAME="astro-webapp-mobile-review-connector-sg"
RDS_SG_NAME="astrodb-shared-rds-sg"
BASTION_SG_NAME="astrodb-shared-bastion-sg"
VPC_CONNECTOR_NAME="astro-webapp-mobile-review-connector"
BASTION_ROLE_NAME="astrodb-shared-bastion-role"
BASTION_PROFILE_NAME="astrodb-shared-bastion-profile"
BASTION_NAME_TAG="astrodb-shared-bastion"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[$(date '+%H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

gen_password() {
  python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(24)))"
}

save_state() {
  cat > "${STATE_FILE}" <<EOF
ACCOUNT_ID="${ACCOUNT_ID:-}"
ECR_REPO_URI="${ECR_REPO_URI:-}"
APP_RUNNER_ECR_ROLE_ARN="${APP_RUNNER_ECR_ROLE_ARN:-}"
APP_RUNNER_SERVICE_ARN="${APP_RUNNER_SERVICE_ARN:-}"
APP_RUNNER_URL="${APP_RUNNER_URL:-}"
CI_ACCESS_KEY_ID="${CI_ACCESS_KEY_ID:-}"
VPC_ID="${VPC_ID:-}"
SUBNET_IDS="${SUBNET_IDS:-}"
PUBLIC_SUBNET_ID="${PUBLIC_SUBNET_ID:-}"
CONNECTOR_SG_ID="${CONNECTOR_SG_ID:-}"
RDS_SG_ID="${RDS_SG_ID:-}"
BASTION_SG_ID="${BASTION_SG_ID:-}"
DB_PASSWORD="${DB_PASSWORD:-}"
ASTRODB_OWNER_PASSWORD="${ASTRODB_OWNER_PASSWORD:-}"
ASTRODB_READER_PASSWORD="${ASTRODB_READER_PASSWORD:-}"
RDS_ENDPOINT="${RDS_ENDPOINT:-}"
BASTION_INSTANCE_ID="${BASTION_INSTANCE_ID:-}"
VPC_CONNECTOR_ARN="${VPC_CONNECTOR_ARN:-}"
EOF
}

load_state() {
  [[ -f "${STATE_FILE}" ]] || err "No state file found at ${STATE_FILE}. Run setup first."
  # shellcheck source=/dev/null
  source "${STATE_FILE}"
  [[ -n "${APP_RUNNER_SERVICE_ARN:-}" ]] || err "State file incomplete — APP_RUNNER_SERVICE_ARN missing. Check ${STATE_FILE}."
}

load_full_state() {
  load_state
  [[ -n "${RDS_ENDPOINT:-}" ]] || err "State file is missing RDS info — this may be from an older setup. Run teardown then setup."
  [[ -n "${BASTION_INSTANCE_ID:-}" ]] || err "State file is missing bastion info — this may be from an older setup. Run teardown then setup."
  [[ -n "${DB_PASSWORD:-}" ]] || err "State file is missing DB credentials — this may be from an older setup. Run teardown then setup."
}

require_aws_cli() {
  command -v aws > /dev/null 2>&1 || err "AWS CLI not found. Install from https://aws.amazon.com/cli/"
  aws sts get-caller-identity > /dev/null 2>&1 || err "AWS CLI not configured. Run: aws configure"
}

require_docker() {
  command -v docker > /dev/null 2>&1 || err "Docker not found."
  docker info > /dev/null 2>&1 || err "Docker daemon is not running. Start Docker Desktop."
}

# ---------------------------------------------------------------------------
# Wait for App Runner service to reach RUNNING (polls every 15s, up to 6 min)
# ---------------------------------------------------------------------------

wait_for_service() {
  local label="${1:-}"
  local max=24
  local i=0
  local status=""
  log "  Waiting for App Runner service ${label} (up to 6 min)..."
  while [[ $i -lt $max ]]; do
    status=$(aws apprunner describe-service \
      --service-arn "${APP_RUNNER_SERVICE_ARN}" \
      --query "Service.Status" --output text --region "${REGION}" 2>/dev/null || echo "UNKNOWN")
    if [[ "${status}" == "RUNNING" ]]; then
      log "  Service is RUNNING"
      return 0
    fi
    if [[ "${status}" == "CREATE_FAILED" || "${status}" == "DELETE_FAILED" ]]; then
      err "App Runner service entered ${status}. Check the AWS console for details."
    fi
    i=$((i + 1))
    log "  Status: ${status} (${i}/${max}) — retrying in 15s..."
    sleep 15
  done
  err "App Runner service did not reach RUNNING after $((max * 15))s."
}

# ---------------------------------------------------------------------------
# Print SSM tunnel instructions (reused by db-init and load-data)
# ---------------------------------------------------------------------------

print_ssm_tunnel() {
  echo ""
  echo "  Terminal 1 — open tunnel (leave running):"
  echo "    aws ssm start-session \\"
  echo "      --target ${BASTION_INSTANCE_ID} \\"
  echo "      --document-name AWS-StartPortForwardingSessionToRemoteHost \\"
  echo "      --parameters \"{\\\"host\\\":[\\\"${RDS_ENDPOINT}\\\"],\\\"portNumber\\\":[\\\"5432\\\"],\\\"localPortNumber\\\":[\\\"${LOCAL_DB_TUNNEL_PORT}\\\"]}\" \\"
  echo "      --region ${REGION}"
}

# ---------------------------------------------------------------------------
# GitHub Actions workflow
# ---------------------------------------------------------------------------

create_github_workflow() {
  local workflow_dir="${REPO_ROOT}/.github/workflows"
  local workflow_file="${workflow_dir}/mobile-review.yml"
  mkdir -p "${workflow_dir}"

  cat > "${workflow_file}" <<'WORKFLOW'
name: Deploy mobile review

on:
  push:
    branches: [mobile-review]

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read

    steps:
      - uses: actions/checkout@v6

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v6
        with:
          aws-access-key-id:     ${{ secrets.MOBILE_REVIEW_AWS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.MOBILE_REVIEW_AWS_SECRET }}
          aws-region:            us-east-1

      - name: Login to ECR
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push
        env:
          IMAGE_URI: ${{ secrets.MOBILE_REVIEW_AWS_ACCOUNT_ID }}.dkr.ecr.us-east-1.amazonaws.com/astro-webapp:mobile-review
        run: |
          docker build -t "$IMAGE_URI" -f web/Dockerfile web/
          docker push "$IMAGE_URI"

      - name: Deploy to App Runner
        run: |
          aws apprunner start-deployment \
            --service-arn "${{ secrets.MOBILE_REVIEW_APP_RUNNER_ARN }}" \
            --region us-east-1
WORKFLOW

  log "  GitHub Actions workflow written: .github/workflows/mobile-review.yml"
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

setup() {
  require_aws_cli
  require_docker

  [[ -f "${STATE_FILE}" ]] && err "State file already exists at ${STATE_FILE}. Run teardown first or check 'status'."

  ACCOUNT_ID="" ECR_REPO_URI="" APP_RUNNER_ECR_ROLE_ARN="" APP_RUNNER_SERVICE_ARN=""
  APP_RUNNER_URL="" CI_ACCESS_KEY_ID="" VPC_ID="" SUBNET_IDS="" PUBLIC_SUBNET_ID=""
  CONNECTOR_SG_ID="" RDS_SG_ID="" BASTION_SG_ID="" DB_PASSWORD="" ASTRODB_OWNER_PASSWORD=""
  ASTRODB_READER_PASSWORD="" RDS_ENDPOINT="" BASTION_INSTANCE_ID="" VPC_CONNECTOR_ARN=""

  trap 'save_state 2>/dev/null || true' EXIT

  log "Starting integration environment setup..."

  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  log "Account: ${ACCOUNT_ID}"
  ECR_REPO_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO_NAME}"

  # ── VPC and subnets ──────────────────────────────────────────────────────────
  log "Discovering default VPC..."
  VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=is-default,Values=true" \
    --query "Vpcs[0].VpcId" --output text --region "${REGION}")
  [[ -n "${VPC_ID}" && "${VPC_ID}" != "None" ]] || err "No default VPC found in ${REGION}."
  log "  VPC: ${VPC_ID}"

  SUBNET_IDS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "Subnets[*].SubnetId" --output text --region "${REGION}")
  PUBLIC_SUBNET_ID=$(echo "${SUBNET_IDS}" | awk '{print $1}')
  # App Runner does not support use1-az3 in us-east-1 — filter it out for the VPC connector
  APPRUNNER_SUBNET_IDS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "Subnets[?AvailabilityZoneId!='use1-az3'].SubnetId" --output text --region "${REGION}")
  log "  Subnets (all):            ${SUBNET_IDS}"
  log "  Subnets (App Runner safe): ${APPRUNNER_SUBNET_IDS}"
  save_state

  # ── ECR Repository ────────────────────────────────────────────────────────────
  log "Creating ECR repository..."
  if aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" --region "${REGION}" > /dev/null 2>&1; then
    log "  ECR repository already exists — reusing"
  else
    aws ecr create-repository \
      --repository-name "${ECR_REPO_NAME}" \
      --image-scanning-configuration scanOnPush=true \
      --encryption-configuration encryptionType=AES256 \
      --region "${REGION}" > /dev/null

    LIFECYCLE_POLICY=$(cat <<'EOF'
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Keep last 10 mobile-review images",
      "selection": {
        "tagStatus": "tagged",
        "tagPrefixList": ["mobile-review"],
        "countType": "imageCountMoreThan",
        "countNumber": 10
      },
      "action": {"type": "expire"}
    },
    {
      "rulePriority": 2,
      "description": "Expire untagged images after 1 day",
      "selection": {
        "tagStatus": "untagged",
        "countType": "sinceImagePushed",
        "countUnit": "days",
        "countNumber": 1
      },
      "action": {"type": "expire"}
    }
  ]
}
EOF
)
    aws ecr put-lifecycle-policy \
      --repository-name "${ECR_REPO_NAME}" \
      --lifecycle-policy-text "${LIFECYCLE_POLICY}" \
      --region "${REGION}" > /dev/null
    log "  ECR repository created: ${ECR_REPO_URI}"
  fi
  save_state

  # ── App Runner ECR Access Role ─────────────────────────────────────────────
  log "Creating App Runner ECR access role..."
  if aws iam get-role --role-name "${APP_RUNNER_ECR_ROLE_NAME}" > /dev/null 2>&1; then
    APP_RUNNER_ECR_ROLE_ARN=$(aws iam get-role \
      --role-name "${APP_RUNNER_ECR_ROLE_NAME}" \
      --query "Role.Arn" --output text)
    log "  IAM role already exists — reusing ${APP_RUNNER_ECR_ROLE_ARN}"
  else
    APP_RUNNER_ECR_ROLE_ARN=$(aws iam create-role \
      --role-name "${APP_RUNNER_ECR_ROLE_NAME}" \
      --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
          "Effect": "Allow",
          "Principal": {"Service": "build.apprunner.amazonaws.com"},
          "Action": "sts:AssumeRole"
        }]
      }' \
      --query "Role.Arn" --output text)
    aws iam attach-role-policy \
      --role-name "${APP_RUNNER_ECR_ROLE_NAME}" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess
    log "  Waiting 10s for IAM propagation..."
    sleep 10
    log "  App Runner ECR role created: ${APP_RUNNER_ECR_ROLE_ARN}"
  fi
  save_state

  # ── Generate DB passwords ─────────────────────────────────────────────────
  log "Generating database passwords..."
  DB_PASSWORD=$(gen_password)
  ASTRODB_OWNER_PASSWORD=$(gen_password)
  ASTRODB_READER_PASSWORD=$(gen_password)
  save_state

  # ── Security groups ───────────────────────────────────────────────────────
  log "Creating security groups..."

  # Connector SG — App Runner egress into VPC
  CONNECTOR_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${CONNECTOR_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[0].GroupId" --output text --region "${REGION}" 2>/dev/null || echo "None")
  if [[ "${CONNECTOR_SG_ID}" == "None" || -z "${CONNECTOR_SG_ID}" ]]; then
    CONNECTOR_SG_ID=$(aws ec2 create-security-group \
      --group-name "${CONNECTOR_SG_NAME}" \
      --description "App Runner VPC connector egress - mobile-review" \
      --vpc-id "${VPC_ID}" \
      --region "${REGION}" \
      --query "GroupId" --output text)
    # Remove default outbound-all rule is not needed; keep it for egress to RDS
    log "  Connector SG: ${CONNECTOR_SG_ID}"
  else
    log "  Connector SG already exists — reusing ${CONNECTOR_SG_ID}"
  fi
  save_state

  # Bastion SG — no inbound; outbound for SSM (port 443)
  BASTION_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${BASTION_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[0].GroupId" --output text --region "${REGION}" 2>/dev/null || echo "None")
  if [[ "${BASTION_SG_ID}" == "None" || -z "${BASTION_SG_ID}" ]]; then
    BASTION_SG_ID=$(aws ec2 create-security-group \
      --group-name "${BASTION_SG_NAME}" \
      --description "Shared SSM bastion - no inbound, outbound for SSM" \
      --vpc-id "${VPC_ID}" \
      --region "${REGION}" \
      --query "GroupId" --output text)
    # Remove default inbound rule (there is none by default) and keep outbound-all
    log "  Bastion SG: ${BASTION_SG_ID}"
  else
    log "  Bastion SG already exists — reusing ${BASTION_SG_ID}"
  fi
  save_state

  # RDS SG — inbound 5432 from connector-sg and bastion-sg only
  RDS_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${RDS_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[0].GroupId" --output text --region "${REGION}" 2>/dev/null || echo "None")
  if [[ "${RDS_SG_ID}" == "None" || -z "${RDS_SG_ID}" ]]; then
    RDS_SG_ID=$(aws ec2 create-security-group \
      --group-name "${RDS_SG_NAME}" \
      --description "Shared RDS - inbound 5432 from connector and bastion only" \
      --vpc-id "${VPC_ID}" \
      --region "${REGION}" \
      --query "GroupId" --output text)
    aws ec2 authorize-security-group-ingress \
      --group-id "${RDS_SG_ID}" \
      --ip-permissions \
        "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=${CONNECTOR_SG_ID},Description=AppRunner}]" \
        "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=${BASTION_SG_ID},Description=Bastion}]" \
      --region "${REGION}" > /dev/null
    log "  RDS SG: ${RDS_SG_ID}"
  else
    log "  RDS SG already exists — reusing ${RDS_SG_ID}"
  fi
  save_state

  # ── DB subnet group ───────────────────────────────────────────────────────
  log "Creating DB subnet group..."
  if aws rds describe-db-subnet-groups \
      --db-subnet-group-name "${DB_SUBNET_GROUP}" \
      --region "${REGION}" > /dev/null 2>&1; then
    log "  DB subnet group already exists — reusing"
  else
    aws rds create-db-subnet-group \
      --db-subnet-group-name "${DB_SUBNET_GROUP}" \
      --db-subnet-group-description "Shared integration DB subnet group" \
      --subnet-ids ${SUBNET_IDS} \
      --region "${REGION}" > /dev/null
    log "  DB subnet group created: ${DB_SUBNET_GROUP}"
  fi

  # ── RDS instance ──────────────────────────────────────────────────────────
  log "Creating RDS PostgreSQL instance (astrodb-shared) — takes 5-10 min..."
  if aws rds describe-db-instances \
      --db-instance-identifier "${DB_INSTANCE_ID}" \
      --region "${REGION}" > /dev/null 2>&1; then
    log "  RDS instance already exists — syncing master password to state..."
    aws rds modify-db-instance \
      --db-instance-identifier "${DB_INSTANCE_ID}" \
      --master-user-password "${DB_PASSWORD}" \
      --apply-immediately \
      --region "${REGION}" > /dev/null
    aws rds wait db-instance-available \
      --db-instance-identifier "${DB_INSTANCE_ID}" \
      --region "${REGION}"
    log "  Password synced"
  else
    aws rds create-db-instance \
      --db-instance-identifier "${DB_INSTANCE_ID}" \
      --db-instance-class db.t3.micro \
      --engine postgres \
      --engine-version "16" \
      --master-username "${DB_USER}" \
      --master-user-password "${DB_PASSWORD}" \
      --db-name "${DB_NAME}" \
      --allocated-storage 20 \
      --storage-type gp2 \
      --no-publicly-accessible \
      --no-multi-az \
      --vpc-security-group-ids "${RDS_SG_ID}" \
      --db-subnet-group-name "${DB_SUBNET_GROUP}" \
      --backup-retention-period 7 \
      --no-deletion-protection \
      --region "${REGION}" > /dev/null
    log "  Waiting for RDS instance to become available..."
    aws rds wait db-instance-available \
      --db-instance-identifier "${DB_INSTANCE_ID}" \
      --region "${REGION}"
    log "  RDS instance available"
  fi

  RDS_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier "${DB_INSTANCE_ID}" \
    --query "DBInstances[0].Endpoint.Address" --output text --region "${REGION}")
  log "  RDS endpoint: ${RDS_ENDPOINT}"
  save_state

  # ── Bastion IAM role ──────────────────────────────────────────────────────
  log "Creating bastion IAM role..."
  if aws iam get-role --role-name "${BASTION_ROLE_NAME}" > /dev/null 2>&1; then
    log "  Bastion IAM role already exists — reusing"
  else
    aws iam create-role \
      --role-name "${BASTION_ROLE_NAME}" \
      --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
          "Effect": "Allow",
          "Principal": {"Service": "ec2.amazonaws.com"},
          "Action": "sts:AssumeRole"
        }]
      }' > /dev/null
    aws iam attach-role-policy \
      --role-name "${BASTION_ROLE_NAME}" \
      --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
    aws iam create-instance-profile \
      --instance-profile-name "${BASTION_PROFILE_NAME}" > /dev/null
    aws iam add-role-to-instance-profile \
      --instance-profile-name "${BASTION_PROFILE_NAME}" \
      --role-name "${BASTION_ROLE_NAME}"
    log "  Waiting 15s for IAM propagation..."
    sleep 15
    log "  Bastion IAM role created"
  fi

  # ── Bastion EC2 ───────────────────────────────────────────────────────────
  log "Launching shared bastion EC2 (SSM access, no key pair)..."
  EXISTING_BASTION=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${BASTION_NAME_TAG}" "Name=instance-state-name,Values=running,stopped,pending" \
    --query "Reservations[0].Instances[0].InstanceId" --output text --region "${REGION}" 2>/dev/null || echo "None")

  if [[ "${EXISTING_BASTION}" == "None" || -z "${EXISTING_BASTION}" ]]; then
    BASTION_AMI=$(aws ec2 describe-images \
      --owners amazon \
      --filters "Name=name,Values=al2023-ami-2023*-x86_64" \
                "Name=state,Values=available" \
                "Name=virtualization-type,Values=hvm" \
      --query "sort_by(Images,&CreationDate)[-1].ImageId" \
      --output text --region "${REGION}")

    BASTION_INSTANCE_ID=$(aws ec2 run-instances \
      --image-id "${BASTION_AMI}" \
      --instance-type t3.nano \
      --iam-instance-profile Name="${BASTION_PROFILE_NAME}" \
      --security-group-ids "${BASTION_SG_ID}" \
      --subnet-id "${PUBLIC_SUBNET_ID}" \
      --associate-public-ip-address \
      --metadata-options HttpTokens=required \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${BASTION_NAME_TAG}},{Key=Project,Value=astrodb-shared}]" \
      --region "${REGION}" \
      --query "Instances[0].InstanceId" --output text)

    log "  Waiting for bastion to reach running state..."
    aws ec2 wait instance-running \
      --instance-ids "${BASTION_INSTANCE_ID}" \
      --region "${REGION}"
    log "  Waiting 30s for SSM agent to register..."
    sleep 30
    log "  Bastion running: ${BASTION_INSTANCE_ID}"
  else
    BASTION_INSTANCE_ID="${EXISTING_BASTION}"
    log "  Bastion already exists — reusing ${BASTION_INSTANCE_ID}"
    # Ensure it's running
    STATE=$(aws ec2 describe-instances \
      --instance-ids "${BASTION_INSTANCE_ID}" \
      --query "Reservations[0].Instances[0].State.Name" --output text --region "${REGION}")
    if [[ "${STATE}" == "stopped" ]]; then
      log "  Bastion is stopped — starting..."
      aws ec2 start-instances --instance-ids "${BASTION_INSTANCE_ID}" --region "${REGION}" > /dev/null
      aws ec2 wait instance-running --instance-ids "${BASTION_INSTANCE_ID}" --region "${REGION}"
      sleep 30
    fi
  fi
  save_state

  # ── VPC Connector ─────────────────────────────────────────────────────────
  log "Creating VPC connector..."
  EXISTING_CONNECTOR=$(aws apprunner list-vpc-connectors --region "${REGION}" \
    --query "VpcConnectors[?VpcConnectorName=='${VPC_CONNECTOR_NAME}' && Status=='ACTIVE'].VpcConnectorArn" \
    --output text 2>/dev/null || true)
  if [[ -n "${EXISTING_CONNECTOR}" && "${EXISTING_CONNECTOR}" != "None" ]]; then
    VPC_CONNECTOR_ARN="${EXISTING_CONNECTOR}"
    log "  VPC connector already exists — reusing"
  else
    VPC_CONNECTOR_ARN=$(aws apprunner create-vpc-connector \
      --vpc-connector-name "${VPC_CONNECTOR_NAME}" \
      --subnets ${APPRUNNER_SUBNET_IDS} \
      --security-groups "${CONNECTOR_SG_ID}" \
      --region "${REGION}" \
      --query "VpcConnector.VpcConnectorArn" --output text)
    log "  VPC connector created: ${VPC_CONNECTOR_ARN}"
  fi
  save_state

  # ── Build and push initial Docker image ───────────────────────────────────
  log "Building Docker image — this takes 2-4 min on first run..."
  aws ecr get-login-password --region "${REGION}" | \
    docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" 2>/dev/null

  docker build \
    --tag "${ECR_REPO_URI}:${IMAGE_TAG}" \
    --file "${REPO_ROOT}/web/Dockerfile" \
    "${REPO_ROOT}/web"

  log "Pushing image to ECR..."
  docker push "${ECR_REPO_URI}:${IMAGE_TAG}" > /dev/null
  log "  Image pushed: ${ECR_REPO_URI}:${IMAGE_TAG}"

  # ── App Runner service ────────────────────────────────────────────────────
  log "Creating App Runner service..."
  EXISTING_ARN=$(aws apprunner list-services --region "${REGION}" \
    --query "ServiceSummaryList[?ServiceName=='${SERVICE_NAME}'].ServiceArn" \
    --output text 2>/dev/null || true)

  if [[ -n "${EXISTING_ARN}" && "${EXISTING_ARN}" != "None" ]]; then
    APP_RUNNER_SERVICE_ARN="${EXISTING_ARN}"
    log "  App Runner service already exists — reusing ${APP_RUNNER_SERVICE_ARN}"
  else
    SOURCE_CONFIG=$(cat <<EOF
{
  "ImageRepository": {
    "ImageIdentifier": "${ECR_REPO_URI}:${IMAGE_TAG}",
    "ImageConfiguration": {
      "Port": "3000",
      "RuntimeEnvironmentVariables": {
        "DATABASE_URL": "postgresql://astrodb_reader:${ASTRODB_READER_PASSWORD}@${RDS_ENDPOINT}:5432/${DB_NAME}?sslmode=require&uselibpqcompat=true",
        "NODE_ENV": "production",
        "NEXT_TELEMETRY_DISABLED": "1",
        "HOSTNAME": "0.0.0.0"
      }
    },
    "ImageRepositoryType": "ECR"
  },
  "AuthenticationConfiguration": {
    "AccessRoleArn": "${APP_RUNNER_ECR_ROLE_ARN}"
  },
  "AutoDeploymentsEnabled": false
}
EOF
)
    APP_RUNNER_SERVICE_ARN=$(aws apprunner create-service \
      --service-name "${SERVICE_NAME}" \
      --source-configuration "${SOURCE_CONFIG}" \
      --instance-configuration Cpu=512,Memory=1024 \
      --network-configuration "{\"EgressConfiguration\":{\"EgressType\":\"VPC\",\"VpcConnectorArn\":\"${VPC_CONNECTOR_ARN}\"}}" \
      --region "${REGION}" \
      --query "Service.ServiceArn" --output text)
    log "  App Runner service created: ${APP_RUNNER_SERVICE_ARN}"
  fi
  save_state

  wait_for_service "reaching RUNNING"

  APP_RUNNER_URL="https://$(aws apprunner describe-service \
    --service-arn "${APP_RUNNER_SERVICE_ARN}" \
    --query "Service.ServiceUrl" --output text --region "${REGION}")"
  save_state

  # ── IAM user for GitHub Actions CI ───────────────────────────────────────
  log "Creating GitHub Actions CI user..."
  local ci_secret=""
  if aws iam get-user --user-name "${CI_USER_NAME}" > /dev/null 2>&1; then
    log "  IAM user already exists — skipping creation"
    CI_ACCESS_KEY_ID=$(aws iam list-access-keys \
      --user-name "${CI_USER_NAME}" \
      --query "AccessKeyMetadata[0].AccessKeyId" --output text 2>/dev/null || echo "")
    ci_secret="(existing key — secret not recoverable; delete and re-run setup if needed)"
  else
    aws iam create-user --user-name "${CI_USER_NAME}" > /dev/null

    CI_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "ECRPush",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage"
      ],
      "Resource": "arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${ECR_REPO_NAME}"
    },
    {
      "Sid": "AppRunnerDeploy",
      "Effect": "Allow",
      "Action": "apprunner:StartDeployment",
      "Resource": "${APP_RUNNER_SERVICE_ARN}"
    }
  ]
}
EOF
)
    aws iam put-user-policy \
      --user-name "${CI_USER_NAME}" \
      --policy-name mobile-review-ci \
      --policy-document "${CI_POLICY}" > /dev/null

    ACCESS_KEY_JSON=$(aws iam create-access-key --user-name "${CI_USER_NAME}")
    CI_ACCESS_KEY_ID=$(echo "${ACCESS_KEY_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['AccessKeyId'])")
    ci_secret=$(echo "${ACCESS_KEY_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['SecretAccessKey'])")
    log "  IAM CI user created: ${CI_USER_NAME}"
  fi
  save_state

  create_github_workflow

  trap - EXIT

  print_summary "${ci_secret}"
}

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------

deploy() {
  load_state
  require_docker

  log "Building updated image..."
  aws ecr get-login-password --region "${REGION}" | \
    docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" 2>/dev/null

  docker build \
    --tag "${ECR_REPO_URI}:${IMAGE_TAG}" \
    --file "${REPO_ROOT}/web/Dockerfile" \
    "${REPO_ROOT}/web"

  log "Pushing image to ECR..."
  docker push "${ECR_REPO_URI}:${IMAGE_TAG}" > /dev/null

  aws apprunner start-deployment \
    --service-arn "${APP_RUNNER_SERVICE_ARN}" \
    --region "${REGION}" > /dev/null
  log "Deployment triggered"

  wait_for_service "redeploying"
  log "Team URL: ${APP_RUNNER_URL}"
}

# ---------------------------------------------------------------------------
# Bastion start / stop
# ---------------------------------------------------------------------------

bastion_start() {
  load_full_state
  STATE=$(aws ec2 describe-instances \
    --instance-ids "${BASTION_INSTANCE_ID}" \
    --query "Reservations[0].Instances[0].State.Name" --output text --region "${REGION}" 2>/dev/null || echo "unknown")
  if [[ "${STATE}" == "running" ]]; then
    log "Bastion is already running: ${BASTION_INSTANCE_ID}"
  else
    log "Starting bastion ${BASTION_INSTANCE_ID}..."
    aws ec2 start-instances --instance-ids "${BASTION_INSTANCE_ID}" --region "${REGION}" > /dev/null
    aws ec2 wait instance-running --instance-ids "${BASTION_INSTANCE_ID}" --region "${REGION}"
    log "  Waiting 30s for SSM agent to register..."
    sleep 30
    log "  Bastion running"
  fi
  print_ssm_tunnel
  echo ""
  echo "  PgAdmin connection (after tunnel is open):"
  echo "    Host: localhost  Port: ${LOCAL_DB_TUNNEL_PORT}  DB: ${DB_NAME}"
  echo "    User: astrodb_owner  Password: (see .mobile-review-state)"
  echo ""
}

bastion_stop() {
  load_full_state
  log "Stopping bastion ${BASTION_INSTANCE_ID}..."
  aws ec2 stop-instances --instance-ids "${BASTION_INSTANCE_ID}" --region "${REGION}" > /dev/null
  aws ec2 wait instance-stopped --instance-ids "${BASTION_INSTANCE_ID}" --region "${REGION}"
  log "  Bastion stopped"
}

# ---------------------------------------------------------------------------
# DB init — print SSM tunnel + db_init.sh instructions
# ---------------------------------------------------------------------------

db_init() {
  load_full_state
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  DB Init — initialise schema and users on ${DB_NAME}"
  echo "════════════════════════════════════════════════════════════════"
  echo ""
  echo "  Bastion must be running. Check with:"
  echo "    ./mobile-review-setup.sh bastion-start"
  echo ""
  print_ssm_tunnel
  echo ""
  echo "  Terminal 2 — run db_init.sh (after tunnel is open):"
  echo "    DATABASE_URL=\"postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${LOCAL_DB_TUNNEL_PORT}/${DB_NAME}?sslmode=require\" \\"
  echo "    ASTRODB_OWNER_PASSWORD=\"${ASTRODB_OWNER_PASSWORD}\" \\"
  echo "    ASTRODB_READER_PASSWORD=\"${ASTRODB_READER_PASSWORD}\" \\"
  echo "    bash ${REPO_ROOT}/app/install/db_init.sh --seed"
  echo ""
  echo "  App Runner is already configured with astrodb_reader credentials."
  echo "  Once db_init.sh completes the app will connect successfully."
  echo ""
}

# ---------------------------------------------------------------------------
# Load data — print SSM tunnel + load_db.py instructions
# ---------------------------------------------------------------------------

load_data() {
  load_full_state
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  Load Data — corpus JSONL → ${DB_NAME}"
  echo "════════════════════════════════════════════════════════════════"
  echo ""
  echo "  Bastion must be running. Check with:"
  echo "    ./mobile-review-setup.sh bastion-start"
  echo ""
  print_ssm_tunnel
  echo ""
  echo "  Terminal 2 — run load_db.py against local JSONL files:"
  echo "    DATABASE_URL=\"postgresql://astrodb_owner:${ASTRODB_OWNER_PASSWORD}@localhost:${LOCAL_DB_TUNNEL_PORT}/${DB_NAME}?sslmode=require\" \\"
  echo "    python3 workarea/scripts/load_db.py --file <path/to/file.jsonl> --verbose"
  echo ""
  echo "  PgAdmin tunnel (same Terminal 1 tunnel):"
  echo "    Host: localhost  Port: ${LOCAL_DB_TUNNEL_PORT}  DB: ${DB_NAME}"
  echo "    User: astrodb_owner  Password: ${ASTRODB_OWNER_PASSWORD}"
  echo ""
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

teardown() {
  load_state

  log "Tearing down mobile review resources..."

  # Check whether staging is live — shared resources must be preserved if so
  STAGING_ARN=$(aws apprunner list-services --region "${REGION}" \
    --query "ServiceSummaryList[?ServiceName=='astro-webapp-staging'].ServiceArn" \
    --output text 2>/dev/null || true)
  STAGING_LIVE=false
  [[ -n "${STAGING_ARN}" && "${STAGING_ARN}" != "None" ]] && STAGING_LIVE=true

  # ── App Runner service ────────────────────────────────────────────────────
  if [[ -n "${APP_RUNNER_SERVICE_ARN:-}" ]]; then
    CURRENT=$(aws apprunner describe-service \
      --service-arn "${APP_RUNNER_SERVICE_ARN}" \
      --query "Service.Status" --output text --region "${REGION}" 2>/dev/null || echo "DELETED")
    if [[ "${CURRENT}" != "DELETED" ]]; then
      log "  Deleting App Runner service..."
      aws apprunner delete-service \
        --service-arn "${APP_RUNNER_SERVICE_ARN}" \
        --region "${REGION}" > /dev/null
      log "  Waiting for App Runner deletion (up to 3 min)..."
      for i in $(seq 1 12); do
        STATUS=$(aws apprunner describe-service \
          --service-arn "${APP_RUNNER_SERVICE_ARN}" \
          --query "Service.Status" --output text --region "${REGION}" 2>/dev/null || echo "DELETED")
        [[ "${STATUS}" == "DELETED" ]] && break
        log "  Status: ${STATUS} (${i}/12)..."
        sleep 15
      done
      log "  App Runner service deleted"
    else
      log "  App Runner service not found — skipping"
    fi
  fi

  # ── VPC connector ─────────────────────────────────────────────────────────
  if [[ -n "${VPC_CONNECTOR_ARN:-}" ]]; then
    log "  Deleting VPC connector..."
    aws apprunner delete-vpc-connector \
      --vpc-connector-arn "${VPC_CONNECTOR_ARN}" \
      --region "${REGION}" > /dev/null 2>&1 || log "  VPC connector not found — skipping"
  fi

  # ── ECR (staging-aware) ───────────────────────────────────────────────────
  if aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" --region "${REGION}" > /dev/null 2>&1; then
    if aws ecr describe-images \
        --repository-name "${ECR_REPO_NAME}" \
        --image-ids imageTag="staging" \
        --region "${REGION}" > /dev/null 2>&1; then
      log "  Staging image detected in ECR — removing mobile-review tag only"
      aws ecr batch-delete-image \
        --repository-name "${ECR_REPO_NAME}" \
        --image-ids imageTag="${IMAGE_TAG}" \
        --region "${REGION}" > /dev/null 2>&1 || true
    else
      log "  No other environments detected — deleting ECR repository"
      aws ecr delete-repository \
        --repository-name "${ECR_REPO_NAME}" \
        --force --region "${REGION}" > /dev/null
    fi
  fi

  # ── IAM CI user ───────────────────────────────────────────────────────────
  if aws iam get-user --user-name "${CI_USER_NAME}" > /dev/null 2>&1; then
    log "  Deleting IAM CI user..."
    KEYS=$(aws iam list-access-keys --user-name "${CI_USER_NAME}" \
      --query "AccessKeyMetadata[].AccessKeyId" --output text 2>/dev/null || true)
    for key_id in ${KEYS}; do
      aws iam delete-access-key --user-name "${CI_USER_NAME}" --access-key-id "${key_id}"
    done
    POLICIES=$(aws iam list-user-policies --user-name "${CI_USER_NAME}" \
      --query "PolicyNames[]" --output text 2>/dev/null || true)
    for policy_name in ${POLICIES}; do
      aws iam delete-user-policy --user-name "${CI_USER_NAME}" --policy-name "${policy_name}"
    done
    aws iam delete-user --user-name "${CI_USER_NAME}"
    log "  IAM CI user deleted"
  fi

  # ── App Runner ECR role (shared with staging) ─────────────────────────────
  if aws iam get-role --role-name "${APP_RUNNER_ECR_ROLE_NAME}" > /dev/null 2>&1; then
    if [[ "${STAGING_LIVE}" == "true" ]]; then
      log "  Staging App Runner detected — skipping ECR role deletion (shared)"
    else
      log "  Deleting App Runner ECR role..."
      aws iam detach-role-policy \
        --role-name "${APP_RUNNER_ECR_ROLE_NAME}" \
        --policy-arn arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess \
        2>/dev/null || true
      aws iam delete-role --role-name "${APP_RUNNER_ECR_ROLE_NAME}"
      log "  App Runner ECR role deleted"
    fi
  fi

  # ── Shared resources — skip if staging is live ────────────────────────────
  if [[ "${STAGING_LIVE}" == "true" ]]; then
    log ""
    log "  ⚠  Staging App Runner service is live — shared RDS, bastion, and SGs preserved."
    log "     Run ./staging_setup.sh teardown first, then re-run this teardown."
    rm -f "${STATE_FILE}"
    log "Done (partial — shared resources retained)."
    return
  fi

  # ── Bastion EC2 ───────────────────────────────────────────────────────────
  if [[ -n "${BASTION_INSTANCE_ID:-}" ]]; then
    log "  Terminating bastion ${BASTION_INSTANCE_ID}..."
    aws ec2 terminate-instances --instance-ids "${BASTION_INSTANCE_ID}" \
      --region "${REGION}" > /dev/null 2>&1 || true
    aws ec2 wait instance-terminated --instance-ids "${BASTION_INSTANCE_ID}" \
      --region "${REGION}" 2>/dev/null || true
    log "  Bastion terminated"
  fi

  # ── Bastion IAM profile and role ──────────────────────────────────────────
  if aws iam get-instance-profile --instance-profile-name "${BASTION_PROFILE_NAME}" > /dev/null 2>&1; then
    log "  Deleting bastion IAM profile..."
    aws iam remove-role-from-instance-profile \
      --instance-profile-name "${BASTION_PROFILE_NAME}" \
      --role-name "${BASTION_ROLE_NAME}" 2>/dev/null || true
    aws iam delete-instance-profile --instance-profile-name "${BASTION_PROFILE_NAME}"
  fi
  if aws iam get-role --role-name "${BASTION_ROLE_NAME}" > /dev/null 2>&1; then
    aws iam detach-role-policy \
      --role-name "${BASTION_ROLE_NAME}" \
      --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
    aws iam delete-role --role-name "${BASTION_ROLE_NAME}"
    log "  Bastion IAM role deleted"
  fi

  # ── RDS instance ──────────────────────────────────────────────────────────
  if aws rds describe-db-instances \
      --db-instance-identifier "${DB_INSTANCE_ID}" \
      --region "${REGION}" > /dev/null 2>&1; then
    log "  Deleting RDS instance (this takes several minutes)..."
    aws rds delete-db-instance \
      --db-instance-identifier "${DB_INSTANCE_ID}" \
      --skip-final-snapshot \
      --region "${REGION}" > /dev/null
    aws rds wait db-instance-deleted \
      --db-instance-identifier "${DB_INSTANCE_ID}" \
      --region "${REGION}"
    log "  RDS instance deleted"
  fi

  # ── DB subnet group ───────────────────────────────────────────────────────
  aws rds delete-db-subnet-group \
    --db-subnet-group-name "${DB_SUBNET_GROUP}" \
    --region "${REGION}" > /dev/null 2>&1 || true

  # ── Security groups (reverse dependency order) ────────────────────────────
  log "  Deleting security groups..."
  for sg_id in "${RDS_SG_ID:-}" "${BASTION_SG_ID:-}" "${CONNECTOR_SG_ID:-}"; do
    [[ -z "${sg_id}" ]] && continue
    aws ec2 delete-security-group --group-id "${sg_id}" \
      --region "${REGION}" > /dev/null 2>&1 || true
  done
  log "  Security groups deleted"

  rm -f "${STATE_FILE}"
  log "Done. All integration environment resources removed."
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

status() {
  load_state

  CURRENT=$(aws apprunner describe-service \
    --service-arn "${APP_RUNNER_SERVICE_ARN}" \
    --query "Service.Status" --output text --region "${REGION}" 2>/dev/null || echo "UNKNOWN")

  BASTION_STATE=$(aws ec2 describe-instances \
    --instance-ids "${BASTION_INSTANCE_ID:-}" \
    --query "Reservations[0].Instances[0].State.Name" --output text --region "${REGION}" 2>/dev/null || echo "unknown")

  echo ""
  echo "  App Runner:  ${CURRENT}"
  echo "  Bastion:     ${BASTION_STATE} (${BASTION_INSTANCE_ID:-n/a})"
  echo "  RDS:         ${RDS_ENDPOINT:-n/a}"
  echo "  Database:    ${DB_NAME}"
  echo ""
  print_summary ""
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
  local ci_secret="${1:-}"
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  Integration environment ready"
  echo "════════════════════════════════════════════════════════════════"
  echo ""
  echo "  Team URL:    ${APP_RUNNER_URL}"
  echo "  ECR repo:    ${ECR_REPO_URI}"
  echo "  Service ARN: ${APP_RUNNER_SERVICE_ARN}"
  echo "  RDS:         ${RDS_ENDPOINT:-n/a} / ${DB_NAME}"
  echo "  Bastion:     ${BASTION_INSTANCE_ID:-n/a}"
  echo ""
  echo "── GitHub Secrets  (repo Settings → Secrets → Actions) ────────"
  echo "  MOBILE_REVIEW_AWS_KEY_ID       = ${CI_ACCESS_KEY_ID}"
  if [[ -n "${ci_secret}" ]]; then
    echo "  MOBILE_REVIEW_AWS_SECRET       = ${ci_secret}"
    echo "  ⚠  Copy the secret above NOW — AWS will not show it again."
  else
    echo "  MOBILE_REVIEW_AWS_SECRET       = (see note above)"
  fi
  echo "  MOBILE_REVIEW_AWS_ACCOUNT_ID   = ${ACCOUNT_ID}"
  echo "  MOBILE_REVIEW_APP_RUNNER_ARN   = ${APP_RUNNER_SERVICE_ARN}"
  echo ""
  echo "── NEXT STEP — initialise the database ─────────────────────────"
  echo "  The app will show DB errors until schema and users are created."
  echo "  Run:  ./mobile-review-setup.sh db-init"
  echo ""
  echo "── Load corpus data ────────────────────────────────────────────"
  echo "  Run:  ./mobile-review-setup.sh load-data"
  echo ""
  echo "── DB access (PgAdmin / psql) ──────────────────────────────────"
  echo "  Run:  ./mobile-review-setup.sh bastion-start"
  echo "  Then open tunnel and connect on localhost:${LOCAL_DB_TUNNEL_PORT}"
  echo ""
  echo "── Push a build ────────────────────────────────────────────────"
  echo "  git push origin <your-branch>:mobile-review"
  echo ""
  echo "── Deploy manually ─────────────────────────────────────────────"
  echo "  ./mobile-review-setup.sh deploy"
  echo ""
  echo "── Teardown ────────────────────────────────────────────────────"
  echo "  ./mobile-review-setup.sh teardown"
  echo "════════════════════════════════════════════════════════════════"
  echo ""
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

case "${1:-setup}" in
  setup)         setup ;;
  teardown)      teardown ;;
  status)        status ;;
  deploy)        deploy ;;
  bastion-start) bastion_start ;;
  bastion-stop)  bastion_stop ;;
  db-init)       db_init ;;
  load-data)     load_data ;;
  *)             echo "Usage: $0 [setup|teardown|status|deploy|bastion-start|bastion-stop|db-init|load-data]"; exit 1 ;;
esac
