#!/usr/bin/env bash
# =============================================================================
# staging_setup.sh — Staging App Runner service + private RDS + SSM bastion
#
# Usage:
#   ./staging_setup.sh               # provision all resources
#   ./staging_setup.sh teardown      # delete all created resources
#   ./staging_setup.sh status        # show service URL and current status
#   ./staging_setup.sh deploy        # build web/ locally and push to staging URL
#   ./staging_setup.sh bastion-start # start the SSM bastion (for DB access)
#   ./staging_setup.sh bastion-stop  # stop the SSM bastion (pauses EC2 charges)
#
# Prerequisites:
#   - AWS CLI configured (aws configure)
#   - AWS Session Manager plugin (for SSM tunnel): https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
#   - Docker Desktop running
#
# RDS is NOT publicly accessible. Use the SSM port-forward command printed at
# the end of setup to reach the DB from a local terminal.
#
# State (including DB credentials) is saved to .staging-state.
# Do NOT commit this file to git.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../" && pwd)"
STATE_FILE="${SCRIPT_DIR}/.staging-state"
REGION="us-east-1"
IMAGE_TAG="staging"

# ECR — shared with mobile-review; only the image tag differs
ECR_REPO_NAME="astro-webapp"

# App Runner
SERVICE_NAME="astro-webapp-staging"
APP_RUNNER_ECR_ROLE_NAME="astro-app-apprunner-ecr-role"   # reused if it already exists
CI_USER_NAME="astro-app-staging-ci"

# RDS
DB_INSTANCE_ID="astro-webapp-staging-db"
DB_NAME="astroweb_staging"
DB_USER="astroweb"
DB_SUBNET_GROUP="astro-webapp-staging-db-subnet-group"

# Networking
CONNECTOR_SG_NAME="astro-webapp-staging-connector-sg"
RDS_SG_NAME="astro-webapp-staging-rds-sg"
BASTION_SG_NAME="astro-webapp-staging-bastion-sg"
VPC_CONNECTOR_NAME="astro-webapp-staging-connector"

# Bastion
BASTION_ROLE_NAME="astro-webapp-staging-bastion-role"
BASTION_PROFILE_NAME="astro-webapp-staging-bastion-profile"
BASTION_NAME_TAG="astro-webapp-staging-bastion"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[$(date '+%H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

generate_password() {
  python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(24)))"
}

save_state() {
  cat > "${STATE_FILE}" <<EOF
ACCOUNT_ID="${ACCOUNT_ID:-}"
ECR_REPO_URI="${ECR_REPO_URI:-}"
APP_RUNNER_ECR_ROLE_ARN="${APP_RUNNER_ECR_ROLE_ARN:-}"
APP_RUNNER_SERVICE_ARN="${APP_RUNNER_SERVICE_ARN:-}"
APP_RUNNER_URL="${APP_RUNNER_URL:-}"
CI_ACCESS_KEY_ID="${CI_ACCESS_KEY_ID:-}"
CONNECTOR_SG_ID="${CONNECTOR_SG_ID:-}"
RDS_SG_ID="${RDS_SG_ID:-}"
BASTION_SG_ID="${BASTION_SG_ID:-}"
BASTION_INSTANCE_ID="${BASTION_INSTANCE_ID:-}"
RDS_ENDPOINT="${RDS_ENDPOINT:-}"
VPC_CONNECTOR_ARN="${VPC_CONNECTOR_ARN:-}"
DB_PASSWORD="${DB_PASSWORD:-}"
DATABASE_URL="${DATABASE_URL:-}"
EOF
}

load_state() {
  [[ -f "${STATE_FILE}" ]] || err "No state file found at ${STATE_FILE}. Run setup first."
  # shellcheck source=/dev/null
  source "${STATE_FILE}"
  [[ -n "${APP_RUNNER_SERVICE_ARN:-}" ]] || err "State file incomplete — APP_RUNNER_SERVICE_ARN missing. Check ${STATE_FILE}."
}

require_aws_cli() {
  command -v aws > /dev/null 2>&1 || err "AWS CLI not found. Install from https://aws.amazon.com/cli/"
  aws sts get-caller-identity > /dev/null 2>&1 || err "AWS CLI not configured. Run: aws configure"
}

require_docker() {
  command -v docker > /dev/null 2>&1 || err "Docker not found. Install Docker Desktop from https://www.docker.com/products/docker-desktop/"
  docker info > /dev/null 2>&1 || err "Docker daemon is not running. Start Docker Desktop."
}

# ---------------------------------------------------------------------------
# Wait for App Runner service to reach RUNNING (polls every 15s, up to 6 min)
# ---------------------------------------------------------------------------

wait_for_service() {
  local label="${1:-}"
  local max=24 i=0 status=""
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
# Create .github/workflows/staging.yml
# ---------------------------------------------------------------------------

create_github_workflow() {
  local workflow_dir="${REPO_ROOT}/.github/workflows"
  local workflow_file="${workflow_dir}/staging.yml"
  mkdir -p "${workflow_dir}"

  cat > "${workflow_file}" <<'WORKFLOW'
name: Deploy staging

on:
  push:
    branches: [staging]

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read

    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id:     ${{ secrets.STAGING_AWS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.STAGING_AWS_SECRET }}
          aws-region:            us-east-1

      - name: Login to ECR
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push
        env:
          IMAGE_URI: ${{ secrets.STAGING_AWS_ACCOUNT_ID }}.dkr.ecr.us-east-1.amazonaws.com/astro-webapp:staging
        run: |
          docker build -t "$IMAGE_URI" -f web/Dockerfile web/
          docker push "$IMAGE_URI"

      - name: Deploy to App Runner
        run: |
          aws apprunner start-deployment \
            --service-arn "${{ secrets.STAGING_APP_RUNNER_ARN }}" \
            --region us-east-1
WORKFLOW

  log "  GitHub Actions workflow written: .github/workflows/staging.yml"
}

# ---------------------------------------------------------------------------
# Database, bastion, and networking infrastructure
#
# RDS is NOT publicly accessible — all access is through the VPC.
# App Runner connects via the VPC connector (connector-sg → rds-sg).
# Developers connect via SSM port-forward through the bastion (bastion-sg → rds-sg).
# The bastion sits in a public subnet with a public IP so SSM can reach AWS
# endpoints without a NAT Gateway. Its security group has zero inbound rules.
# ---------------------------------------------------------------------------

setup_database() {
  log "Setting up database and bastion infrastructure..."

  # Discover default VPC
  local vpc_id
  vpc_id=$(aws ec2 describe-vpcs \
    --filters Name=isDefault,Values=true \
    --query "Vpcs[0].VpcId" --output text --region "${REGION}")
  [[ "${vpc_id}" == "None" || -z "${vpc_id}" ]] && \
    err "No default VPC in ${REGION}. Run: aws ec2 create-default-vpc --region ${REGION}"
  log "  Default VPC: ${vpc_id}"

  # Collect one subnet per AZ (RDS subnet group needs ≥2 AZs; bastion uses first one)
  local subnet_ids=() az_seen=()
  while IFS=$'\t' read -r sid az; do
    local already=false
    for s in "${az_seen[@]:-}"; do [[ "$s" == "$az" ]] && already=true && break; done
    if ! $already; then
      subnet_ids+=("${sid}")
      az_seen+=("${az}")
    fi
  done < <(aws ec2 describe-subnets \
    --filters Name=vpc-id,Values="${vpc_id}" \
    --query "Subnets[*].[SubnetId,AvailabilityZone]" \
    --output text --region "${REGION}")
  [[ ${#subnet_ids[@]} -lt 2 ]] && \
    err "Need at least 2 subnets in different AZs in the default VPC."
  local bastion_subnet="${subnet_ids[0]}"
  log "  Subnets: ${subnet_ids[*]}"

  # ── Security groups ─────────────────────────────────────────────────────────
  log "  Creating security groups..."

  # App Runner VPC connector — outbound only; AWS adds default allow-all-egress
  CONNECTOR_SG_ID=$(aws ec2 create-security-group \
    --group-name "${CONNECTOR_SG_NAME}" \
    --description "Astro staging App Runner VPC connector" \
    --vpc-id "${vpc_id}" \
    --region "${REGION}" \
    --query "GroupId" --output text)
  log "    Connector SG: ${CONNECTOR_SG_ID}"

  # Bastion — no inbound; SSM uses outbound HTTPS (port 443) to AWS endpoints
  BASTION_SG_ID=$(aws ec2 create-security-group \
    --group-name "${BASTION_SG_NAME}" \
    --description "Astro staging SSM bastion (no inbound)" \
    --vpc-id "${vpc_id}" \
    --region "${REGION}" \
    --query "GroupId" --output text)
  log "    Bastion SG:   ${BASTION_SG_ID}"

  # RDS — inbound 5432 only from connector and bastion SGs
  RDS_SG_ID=$(aws ec2 create-security-group \
    --group-name "${RDS_SG_NAME}" \
    --description "Astro staging RDS PostgreSQL" \
    --vpc-id "${vpc_id}" \
    --region "${REGION}" \
    --query "GroupId" --output text)
  log "    RDS SG:       ${RDS_SG_ID}"

  aws ec2 authorize-security-group-ingress \
    --group-id "${RDS_SG_ID}" --protocol tcp --port 5432 \
    --source-group "${CONNECTOR_SG_ID}" \
    --region "${REGION}" > /dev/null
  aws ec2 authorize-security-group-ingress \
    --group-id "${RDS_SG_ID}" --protocol tcp --port 5432 \
    --source-group "${BASTION_SG_ID}" \
    --region "${REGION}" > /dev/null
  log "    RDS SG ingress rules added"

  # ── DB subnet group ─────────────────────────────────────────────────────────
  aws rds create-db-subnet-group \
    --db-subnet-group-name "${DB_SUBNET_GROUP}" \
    --db-subnet-group-description "Astro staging RDS subnet group" \
    --subnet-ids "${subnet_ids[@]}" \
    --region "${REGION}" > /dev/null
  log "  DB subnet group: ${DB_SUBNET_GROUP}"

  # ── RDS PostgreSQL (private) ────────────────────────────────────────────────
  DB_PASSWORD=$(generate_password)
  log "  Creating RDS PostgreSQL 16 (db.t3.micro, 20 GB, private) — 5-10 min..."
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
    --db-subnet-group-name "${DB_SUBNET_GROUP}" \
    --vpc-security-group-ids "${RDS_SG_ID}" \
    --no-publicly-accessible \
    --no-multi-az \
    --backup-retention-period 7 \
    --region "${REGION}" > /dev/null

  save_state  # persist password before the long RDS wait

  # ── EC2 bastion (SSM only — no key pair, no inbound SG rules) ──────────────
  log "  Creating SSM bastion (t3.nano, Amazon Linux 2023)..."

  # IAM role for SSM managed instance
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

  log "  Waiting 15s for IAM instance profile propagation..."
  sleep 15

  # Latest Amazon Linux 2023 AMI (x86_64)
  local ami_id
  ami_id=$(aws ssm get-parameter \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query "Parameter.Value" --output text --region "${REGION}")
  log "    AL2023 AMI: ${ami_id}"

  BASTION_INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "${ami_id}" \
    --instance-type t3.nano \
    --iam-instance-profile Name="${BASTION_PROFILE_NAME}" \
    --security-group-ids "${BASTION_SG_ID}" \
    --subnet-id "${bastion_subnet}" \
    --associate-public-ip-address \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${BASTION_NAME_TAG}}]" \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled \
    --region "${REGION}" \
    --query "Instances[0].InstanceId" --output text)
  log "  Bastion instance: ${BASTION_INSTANCE_ID}"
  save_state

  # ── Wait for RDS and bastion in parallel ────────────────────────────────────
  log "  Waiting for RDS instance to be available (up to 15 min)..."
  aws rds wait db-instance-available \
    --db-instance-identifier "${DB_INSTANCE_ID}" \
    --region "${REGION}"

  RDS_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier "${DB_INSTANCE_ID}" \
    --query "DBInstances[0].Endpoint.Address" --output text --region "${REGION}")
  DATABASE_URL="postgresql://${DB_USER}:${DB_PASSWORD}@${RDS_ENDPOINT}:5432/${DB_NAME}"
  log "  RDS endpoint: ${RDS_ENDPOINT}"

  log "  Waiting for bastion to be running..."
  aws ec2 wait instance-running \
    --instance-ids "${BASTION_INSTANCE_ID}" \
    --region "${REGION}"
  log "  Waiting 30s for SSM agent to register..."
  sleep 30
  log "  Bastion ready"

  # ── App Runner VPC connector ────────────────────────────────────────────────
  log "  Creating App Runner VPC connector..."
  VPC_CONNECTOR_ARN=$(aws apprunner create-vpc-connector \
    --vpc-connector-name "${VPC_CONNECTOR_NAME}" \
    --subnets "${subnet_ids[@]}" \
    --security-groups "${CONNECTOR_SG_ID}" \
    --region "${REGION}" \
    --query "VpcConnector.VpcConnectorArn" --output text)
  log "  VPC connector: ${VPC_CONNECTOR_ARN}"

  save_state
}

# ---------------------------------------------------------------------------
# Teardown database, bastion, and networking (call after App Runner is gone)
# ---------------------------------------------------------------------------

teardown_database() {
  # VPC connector must be deleted before its security group
  if [[ -n "${VPC_CONNECTOR_ARN:-}" ]]; then
    log "  Deleting VPC connector..."
    aws apprunner delete-vpc-connector \
      --vpc-connector-arn "${VPC_CONNECTOR_ARN}" \
      --region "${REGION}" > /dev/null 2>&1 || true
  fi

  # RDS instance
  if aws rds describe-db-instances \
      --db-instance-identifier "${DB_INSTANCE_ID}" \
      --region "${REGION}" > /dev/null 2>&1; then
    log "  Deleting RDS instance (no final snapshot)..."
    aws rds delete-db-instance \
      --db-instance-identifier "${DB_INSTANCE_ID}" \
      --skip-final-snapshot \
      --region "${REGION}" > /dev/null
    log "  Waiting for RDS deletion (up to 15 min)..."
    aws rds wait db-instance-deleted \
      --db-instance-identifier "${DB_INSTANCE_ID}" \
      --region "${REGION}" || true
    log "  RDS instance deleted"
  else
    log "  RDS instance not found — skipping"
  fi

  # DB subnet group
  if aws rds describe-db-subnet-groups \
      --db-subnet-group-name "${DB_SUBNET_GROUP}" \
      --region "${REGION}" > /dev/null 2>&1; then
    aws rds delete-db-subnet-group \
      --db-subnet-group-name "${DB_SUBNET_GROUP}" \
      --region "${REGION}" > /dev/null 2>&1 || true
    log "  DB subnet group deleted"
  fi

  # EC2 bastion
  if [[ -n "${BASTION_INSTANCE_ID:-}" ]]; then
    local state
    state=$(aws ec2 describe-instances \
      --instance-ids "${BASTION_INSTANCE_ID}" \
      --query "Reservations[0].Instances[0].State.Name" \
      --output text --region "${REGION}" 2>/dev/null || echo "terminated")
    if [[ "${state}" != "terminated" ]]; then
      log "  Terminating bastion instance ${BASTION_INSTANCE_ID}..."
      aws ec2 terminate-instances \
        --instance-ids "${BASTION_INSTANCE_ID}" \
        --region "${REGION}" > /dev/null
      log "  Waiting for bastion to terminate..."
      aws ec2 wait instance-terminated \
        --instance-ids "${BASTION_INSTANCE_ID}" \
        --region "${REGION}" || true
      log "  Bastion terminated"
    else
      log "  Bastion already terminated — skipping"
    fi
  fi

  # Bastion IAM instance profile and role
  if aws iam get-instance-profile \
      --instance-profile-name "${BASTION_PROFILE_NAME}" > /dev/null 2>&1; then
    aws iam remove-role-from-instance-profile \
      --instance-profile-name "${BASTION_PROFILE_NAME}" \
      --role-name "${BASTION_ROLE_NAME}" 2>/dev/null || true
    aws iam delete-instance-profile \
      --instance-profile-name "${BASTION_PROFILE_NAME}" 2>/dev/null || true
  fi
  if aws iam get-role --role-name "${BASTION_ROLE_NAME}" > /dev/null 2>&1; then
    aws iam detach-role-policy \
      --role-name "${BASTION_ROLE_NAME}" \
      --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
    aws iam delete-role --role-name "${BASTION_ROLE_NAME}" 2>/dev/null || true
    log "  Bastion IAM role deleted"
  fi

  # Security groups: RDS first (refs the others), then bastion, then connector
  for sg_id in "${RDS_SG_ID:-}" "${BASTION_SG_ID:-}" "${CONNECTOR_SG_ID:-}"; do
    [[ -z "${sg_id}" ]] && continue
    aws ec2 delete-security-group \
      --group-id "${sg_id}" \
      --region "${REGION}" > /dev/null 2>&1 || true
  done
  log "  Security groups deleted"
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

setup() {
  require_aws_cli
  require_docker

  [[ -f "${STATE_FILE}" ]] && err "State file already exists at ${STATE_FILE}. Run teardown first or check 'status'."

  ACCOUNT_ID="" ECR_REPO_URI="" APP_RUNNER_ECR_ROLE_ARN="" APP_RUNNER_SERVICE_ARN="" \
  APP_RUNNER_URL="" CI_ACCESS_KEY_ID="" CONNECTOR_SG_ID="" RDS_SG_ID="" BASTION_SG_ID="" \
  BASTION_INSTANCE_ID="" RDS_ENDPOINT="" VPC_CONNECTOR_ARN="" DB_PASSWORD="" DATABASE_URL=""

  trap 'save_state 2>/dev/null || true' EXIT

  log "Starting staging infrastructure setup..."

  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  log "Account: ${ACCOUNT_ID}"
  ECR_REPO_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO_NAME}"

  # ── ECR Repository (shared with mobile-review; reuse if exists) ─────────────
  log "Checking ECR repository..."
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
      "description": "Keep last 10 images per tag prefix",
      "selection": {
        "tagStatus": "tagged",
        "tagPrefixList": ["mobile-review", "staging"],
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

  # ── App Runner ECR Access Role (reuse if exists) ────────────────────────────
  log "Checking App Runner ECR access role..."
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

  # ── Database + bastion + networking ─────────────────────────────────────────
  setup_database

  # ── Build and push staging image ────────────────────────────────────────────
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

  # ── App Runner Service ──────────────────────────────────────────────────────
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
        "DATABASE_URL": "${DATABASE_URL}",
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
    NETWORK_CONFIG="{\"EgressConfiguration\":{\"EgressType\":\"VPC\",\"VpcConnectorArn\":\"${VPC_CONNECTOR_ARN}\"}}"

    APP_RUNNER_SERVICE_ARN=$(aws apprunner create-service \
      --service-name "${SERVICE_NAME}" \
      --source-configuration "${SOURCE_CONFIG}" \
      --instance-configuration Cpu=256,Memory=512 \
      --network-configuration "${NETWORK_CONFIG}" \
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

  # ── IAM user for GitHub Actions CI ─────────────────────────────────────────
  log "Creating GitHub Actions CI user..."
  local ci_secret=""
  if aws iam get-user --user-name "${CI_USER_NAME}" > /dev/null 2>&1; then
    log "  IAM user already exists — skipping creation"
    CI_ACCESS_KEY_ID=$(aws iam list-access-keys \
      --user-name "${CI_USER_NAME}" \
      --query "AccessKeyMetadata[0].AccessKeyId" --output text 2>/dev/null || echo "")
    ci_secret="(existing key — secret not recoverable; delete the key and re-run setup if needed)"
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
      --policy-name staging-ci \
      --policy-document "${CI_POLICY}" > /dev/null

    ACCESS_KEY_JSON=$(aws iam create-access-key --user-name "${CI_USER_NAME}")
    CI_ACCESS_KEY_ID=$(echo "${ACCESS_KEY_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['AccessKeyId'])")
    ci_secret=$(echo "${ACCESS_KEY_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['SecretAccessKey'])")
    log "  IAM CI user created: ${CI_USER_NAME}"
  fi
  save_state

  # ── GitHub Actions workflow ─────────────────────────────────────────────────
  create_github_workflow

  trap - EXIT

  print_summary "${ci_secret}"
}

# ---------------------------------------------------------------------------
# Deploy — build and push a new image, trigger App Runner redeploy
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
  log "  Image pushed: ${ECR_REPO_URI}:${IMAGE_TAG}"

  aws apprunner start-deployment \
    --service-arn "${APP_RUNNER_SERVICE_ARN}" \
    --region "${REGION}" > /dev/null
  log "Deployment triggered"

  wait_for_service "redeploying"
  log "Staging URL: ${APP_RUNNER_URL}"
}

# ---------------------------------------------------------------------------
# Teardown — removes all staging resources
# ---------------------------------------------------------------------------

teardown() {
  load_state

  log "Tearing down staging resources..."

  # ── App Runner service (must be gone before VPC connector can be deleted)
  if [[ -n "${APP_RUNNER_SERVICE_ARN:-}" ]]; then
    CURRENT=$(aws apprunner describe-service \
      --service-arn "${APP_RUNNER_SERVICE_ARN}" \
      --query "Service.Status" --output text --region "${REGION}" 2>/dev/null || echo "DELETED")
    if [[ "${CURRENT}" != "DELETED" ]]; then
      log "  Deleting App Runner service..."
      aws apprunner delete-service \
        --service-arn "${APP_RUNNER_SERVICE_ARN}" \
        --region "${REGION}" > /dev/null
      log "  Waiting for App Runner service deletion (up to 3 min)..."
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

  # ── ECR — delete only the staging-tagged image; do not delete the shared repo
  log "  Removing staging image from ECR..."
  aws ecr batch-delete-image \
    --repository-name "${ECR_REPO_NAME}" \
    --image-ids imageTag="${IMAGE_TAG}" \
    --region "${REGION}" > /dev/null 2>&1 || true
  log "  Staging image removed"

  # ── IAM CI user
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
  else
    log "  IAM CI user not found — skipping"
  fi

  # ── Database, bastion, VPC connector, security groups
  teardown_database

  rm -f "${STATE_FILE}"
  log "Done. All staging resources removed."
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

status() {
  load_state

  CURRENT=$(aws apprunner describe-service \
    --service-arn "${APP_RUNNER_SERVICE_ARN}" \
    --query "Service.Status" --output text --region "${REGION}" 2>/dev/null || echo "UNKNOWN")

  echo ""
  echo "  Service status: ${CURRENT}"

  print_summary ""
}

# ---------------------------------------------------------------------------
# Bastion start / stop
# ---------------------------------------------------------------------------

bastion_start() {
  load_state
  [[ -z "${BASTION_INSTANCE_ID:-}" ]] && err "No bastion in state. Run setup first."

  local state
  state=$(aws ec2 describe-instances \
    --instance-ids "${BASTION_INSTANCE_ID}" \
    --query "Reservations[0].Instances[0].State.Name" \
    --output text --region "${REGION}" 2>/dev/null || echo "unknown")

  if [[ "${state}" == "running" ]]; then
    log "Bastion is already running"
    print_ssm_tunnel
    return 0
  fi

  log "Starting bastion ${BASTION_INSTANCE_ID}..."
  aws ec2 start-instances \
    --instance-ids "${BASTION_INSTANCE_ID}" \
    --region "${REGION}" > /dev/null
  aws ec2 wait instance-running \
    --instance-ids "${BASTION_INSTANCE_ID}" \
    --region "${REGION}"
  log "Instance running. Waiting 30s for SSM agent to register..."
  sleep 30
  log "Bastion ready."
  print_ssm_tunnel
}

bastion_stop() {
  load_state
  [[ -z "${BASTION_INSTANCE_ID:-}" ]] && err "No bastion in state. Run setup first."

  local state
  state=$(aws ec2 describe-instances \
    --instance-ids "${BASTION_INSTANCE_ID}" \
    --query "Reservations[0].Instances[0].State.Name" \
    --output text --region "${REGION}" 2>/dev/null || echo "unknown")

  if [[ "${state}" == "stopped" ]]; then
    log "Bastion is already stopped"
    return 0
  fi

  log "Stopping bastion ${BASTION_INSTANCE_ID}..."
  aws ec2 stop-instances \
    --instance-ids "${BASTION_INSTANCE_ID}" \
    --region "${REGION}" > /dev/null
  aws ec2 wait instance-stopped \
    --instance-ids "${BASTION_INSTANCE_ID}" \
    --region "${REGION}"
  log "Bastion stopped. EC2 compute charges paused."
}

# ---------------------------------------------------------------------------
# SSM tunnel instructions (reused by setup summary and bastion-start)
# ---------------------------------------------------------------------------

print_ssm_tunnel() {
  echo ""
  echo "  Terminal 1 — open tunnel:"
  echo "    aws ssm start-session \\"
  echo "      --target ${BASTION_INSTANCE_ID:-<INSTANCE_ID>} \\"
  echo "      --document-name AWS-StartPortForwardingSessionToRemoteHost \\"
  echo "      --parameters 'host=${RDS_ENDPOINT:-<RDS_ENDPOINT>},portNumber=5432,localPortNumber=5432' \\"
  echo "      --region ${REGION}"
  echo ""
  echo "  Terminal 2 — connect:"
  echo "    psql \"postgresql://${DB_USER}:${DB_PASSWORD:-<PASSWORD>}@localhost:5432/${DB_NAME}\""
  echo ""
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
  local ci_secret="${1:-}"
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  Staging infrastructure ready"
  echo "════════════════════════════════════════════════════════════════"
  echo ""
  echo "  Staging URL: ${APP_RUNNER_URL:-N/A}"
  echo "  ECR repo:    ${ECR_REPO_URI:-N/A}"
  echo "  Service ARN: ${APP_RUNNER_SERVICE_ARN:-N/A}"
  echo ""
  echo "── GitHub Secrets  (repo Settings → Secrets → Actions) ────────"
  echo "  STAGING_AWS_KEY_ID       = ${CI_ACCESS_KEY_ID:-N/A}"
  if [[ -n "${ci_secret}" ]]; then
    echo "  STAGING_AWS_SECRET       = ${ci_secret}"
    echo "  ⚠  Copy the secret above NOW — AWS will not show it again."
  else
    echo "  STAGING_AWS_SECRET       = (see note above)"
  fi
  echo "  STAGING_AWS_ACCOUNT_ID   = ${ACCOUNT_ID:-N/A}"
  echo "  STAGING_APP_RUNNER_ARN   = ${APP_RUNNER_SERVICE_ARN:-N/A}"
  echo ""
  echo "── Database access (SSM port-forward — RDS is private) ────────"
  echo "  Bastion: ${BASTION_INSTANCE_ID:-N/A}   RDS: ${RDS_ENDPOINT:-N/A}"
  echo ""
  echo "  Prereq: SSM Session Manager plugin"
  echo "    https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
  echo ""
  echo "  Start bastion (stopped by default to save cost):"
  echo "    ./staging_setup.sh bastion-start"
  print_ssm_tunnel
  echo "  Stop bastion when done:"
  echo "    ./staging_setup.sh bastion-stop"
  echo ""
  echo "  ⚠  .staging-state contains the DB password — keep it out of git."
  echo ""
  echo "── Workflow file ───────────────────────────────────────────────"
  echo "  .github/workflows/staging.yml"
  echo "  Commit it, then push to staging branch to trigger auto-deploy."
  echo ""
  echo "── Push a build to staging ─────────────────────────────────────"
  echo "  git push origin <your-branch>:staging"
  echo ""
  echo "── Deploy manually (no git push) ───────────────────────────────"
  echo "  ./staging_setup.sh deploy"
  echo ""
  echo "── Teardown ─────────────────────────────────────────────────────"
  echo "  ./staging_setup.sh teardown"
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
  *)             echo "Usage: $0 [setup|teardown|status|deploy|bastion-start|bastion-stop]"; exit 1 ;;
esac
