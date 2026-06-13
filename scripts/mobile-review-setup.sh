#!/usr/bin/env bash
# =============================================================================
# mobile-review-setup.sh — Mobile review App Runner service + GitHub Actions CI
#
# Usage:
#   ./mobile-review-setup.sh          # create ECR repo, App Runner service, CI user
#   ./mobile-review-setup.sh teardown # delete all created resources
#   ./mobile-review-setup.sh status   # show service URL and current status
#   ./mobile-review-setup.sh deploy   # build web/ locally and push to team URL
#
# Prerequisites:
#   - AWS CLI configured (aws configure)
#   - Docker Desktop running
#
# The CI IAM user's secret key is printed ONCE during setup.
# Copy it to GitHub Secrets immediately — AWS will not show it again.
#
# State is saved to .mobile-review-state in the same directory as this script.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../" && pwd)"
STATE_FILE="${SCRIPT_DIR}/.mobile-review-state"
REGION="us-east-1"
ECR_REPO_NAME="astro-webapp"
SERVICE_NAME="astro-webapp-mobile-review"
APP_RUNNER_ECR_ROLE_NAME="astro-app-apprunner-ecr-role"
CI_USER_NAME="astro-app-mobile-review-ci"
IMAGE_TAG="mobile-review"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[$(date '+%H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

# Windows corporate SSL — suppress InsecureRequestWarning via Python env var
# (process substitution is unreliable in Git Bash on Windows)
aws() { PYTHONWARNINGS=ignore command aws --no-verify-ssl "$@"; }

# Secret key is NOT persisted — shown once at setup, must be copied to GitHub Secrets
save_state() {
  cat > "${STATE_FILE}" <<EOF
ACCOUNT_ID="${ACCOUNT_ID:-}"
ECR_REPO_URI="${ECR_REPO_URI:-}"
APP_RUNNER_ECR_ROLE_ARN="${APP_RUNNER_ECR_ROLE_ARN:-}"
APP_RUNNER_SERVICE_ARN="${APP_RUNNER_SERVICE_ARN:-}"
APP_RUNNER_URL="${APP_RUNNER_URL:-}"
CI_ACCESS_KEY_ID="${CI_ACCESS_KEY_ID:-}"
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
  err "App Runner service did not reach RUNNING after $((max * 15))s. Check the AWS console."
}

# ---------------------------------------------------------------------------
# Create .github/workflows/mobile-review.yml in the repo root
# ---------------------------------------------------------------------------

create_github_workflow() {
  local workflow_dir="${REPO_ROOT}/.github/workflows"
  local workflow_file="${workflow_dir}/mobile-review.yml"
  mkdir -p "${workflow_dir}"

  # Single-quoted delimiter — bash must NOT expand ${{ }} GitHub Actions syntax
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
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
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

  ACCOUNT_ID="" ECR_REPO_URI="" APP_RUNNER_ECR_ROLE_ARN="" APP_RUNNER_SERVICE_ARN="" APP_RUNNER_URL="" CI_ACCESS_KEY_ID=""

  trap 'save_state 2>/dev/null || true' EXIT

  log "Starting mobile review infrastructure setup..."

  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  log "Account: ${ACCOUNT_ID}"
  ECR_REPO_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO_NAME}"

  # ── ECR Repository ──────────────────────────────────────────────────────────
  log "Creating ECR repository..."
  if aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" --region "${REGION}" > /dev/null 2>&1; then
    log "  ECR repository already exists — skipping"
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

  # ── App Runner ECR Access Role ──────────────────────────────────────────────
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

  # ── Build and push initial image ────────────────────────────────────────────
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
        "MOCK_DB": "true",
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
      --policy-name mobile-review-ci \
      --policy-document "${CI_POLICY}" > /dev/null

    ACCESS_KEY_JSON=$(aws iam create-access-key --user-name "${CI_USER_NAME}")
    CI_ACCESS_KEY_ID=$(echo "${ACCESS_KEY_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['AccessKeyId'])")
    ci_secret=$(echo "${ACCESS_KEY_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['SecretAccessKey'])")
    log "  IAM CI user created: ${CI_USER_NAME}"
  fi
  save_state

  # ── GitHub Actions workflow file ────────────────────────────────────────────
  create_github_workflow

  trap - EXIT

  print_summary "${ci_secret}"
}

# ---------------------------------------------------------------------------
# Deploy — build web/ locally and push a new image to App Runner
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
  log "Team URL: ${APP_RUNNER_URL}"
}

# ---------------------------------------------------------------------------
# Teardown — removes App Runner service, ECR repo, IAM user, ECR role
# ---------------------------------------------------------------------------

teardown() {
  load_state

  log "Tearing down mobile review resources..."

  # ── App Runner service
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

  # ── ECR repository (--force deletes all images)
  if aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" --region "${REGION}" > /dev/null 2>&1; then
    log "  Deleting ECR repository and all images..."
    aws ecr delete-repository \
      --repository-name "${ECR_REPO_NAME}" \
      --force \
      --region "${REGION}" > /dev/null
    log "  ECR repository deleted"
  else
    log "  ECR repository not found — skipping"
  fi

  # ── IAM CI user (keys + inline policies must be removed before delete-user)
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

  # ── App Runner ECR role
  if aws iam get-role --role-name "${APP_RUNNER_ECR_ROLE_NAME}" > /dev/null 2>&1; then
    log "  Deleting App Runner ECR role..."
    aws iam detach-role-policy \
      --role-name "${APP_RUNNER_ECR_ROLE_NAME}" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess \
      2>/dev/null || true
    aws iam delete-role --role-name "${APP_RUNNER_ECR_ROLE_NAME}"
    log "  App Runner ECR role deleted"
  else
    log "  App Runner ECR role not found — skipping"
  fi

  rm -f "${STATE_FILE}"
  log "Done. All mobile review resources removed."
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
# Summary
# ---------------------------------------------------------------------------

print_summary() {
  local ci_secret="${1:-}"
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  Mobile review infrastructure ready"
  echo "════════════════════════════════════════════════════════════════"
  echo ""
  echo "  Team URL:    ${APP_RUNNER_URL}"
  echo "  ECR repo:    ${ECR_REPO_URI}"
  echo "  Service ARN: ${APP_RUNNER_SERVICE_ARN}"
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
  echo "── Workflow file ───────────────────────────────────────────────"
  echo "  .github/workflows/mobile-review.yml"
  echo "  Commit it, then push to mobile-review to trigger auto-deploy."
  echo ""
  echo "── Push a build to the team ────────────────────────────────────"
  echo "  git push origin <your-branch>:mobile-review"
  echo "  GitHub Actions builds and deploys automatically (~4 min)."
  echo ""
  echo "── Deploy manually (no git push) ───────────────────────────────"
  echo "  ./mobile-review-setup.sh deploy"
  echo ""
  echo "── Teardown ─────────────────────────────────────────────────────"
  echo "  ./mobile-review-setup.sh teardown"
  echo "════════════════════════════════════════════════════════════════"
  echo ""
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

case "${1:-setup}" in
  setup)    setup ;;
  teardown) teardown ;;
  status)   status ;;
  deploy)   deploy ;;
  *)        echo "Usage: $0 [setup|teardown|status|deploy]"; exit 1 ;;
esac
