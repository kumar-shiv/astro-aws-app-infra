# AWS SLM App Infrastructure - Terraform Setup Complete

## Overview
Comprehensive Terraform IaC has been created for a multi-tier AWS infrastructure supporting:
- Containerized Ollama SLM deployment on Fargate
- Multi-AZ PostgreSQL RDS database
- S3 data pipeline (raw → processed output)
- Secure multi-subnet architecture with proper access controls

## Project Structure

```
.
├── terraform/
│   ├── aws_provider.tf          # AWS provider config
│   ├── main.tf                  # Root module composition
│   ├── variables.tf             # Input variables
│   ├── terraform.tfvars         # Configuration values
│   ├── outputs.tf               # Root outputs
│   ├── .terraform/              # Terraform cache (gitignored)
│   ├── .terraform.lock.hcl      # Provider lock file
│   │
│   └── modules/
│       ├── vpc/                 # VPC + IGW + public subnets
│       ├── nat_gateway/         # NAT Gateways + Elastic IPs
│       ├── private_subnets/     # 8 private subnets (4 types × 2 AZs)
│       ├── security_groups/     # All security groups + rules
│       ├── vpc_endpoints/       # S3, ECR, CloudWatch Logs endpoints
│       ├── s3/                  # S3 buckets + bucket policies
│       ├── rds/                 # PostgreSQL Multi-AZ instance
│       ├── iam/                 # ECS task roles + S3/Secrets policies
│       ├── ecs_cluster/         # ECS cluster + CloudWatch logging
│       └── ollama_fargate/      # Ollama ECS Fargate service
│
└── .gitignore                   # Terraform-specific ignores
```

## Infrastructure Components

### Network
- **VPC**: 10.0.0.0/16
- **Public Subnets**: 2 (for NAT Gateways)
- **Private Subnets**: 8 total
  - 2 Database subnets (db_subnet)
  - 2 LLM subnets (ollama deployment)
  - 2 Application subnets
  - 2 Frontend subnets
- **NAT Gateways**: 2 (high-availability across AZs)
- **VPC Endpoints**: S3, ECR API, ECR DKR, CloudWatch Logs, Secrets Manager

### Compute
- **ECS Cluster**: Fargate-only, container insights enabled
- **Ollama Service**: 2 replicas (configurable) in llm_subnet
  - CPU: 2 vCPU (configurable)
  - Memory: 8GB (configurable)
  - Auto-scaling based on CPU/memory metrics
  - Health checks via HTTP API

### Data
- **PostgreSQL RDS**: Multi-AZ, encrypted, automated backups
  - Instance class: db.t3.medium (configurable)
  - Storage: 20GB with auto-scaling
  - Backup retention: 7 days (configurable)
- **S3 Buckets**: raw, output, wiki
  - Encryption enabled (AES256)
  - Versioning enabled
  - Public access blocked

### Security
- **Security Groups**: Properly configured for each tier
  - Frontend ← Internet (80/443)
  - App ← Frontend (80/443)
  - LLM ← App (11434)
  - RDS ← App (5432)
  - VPC Endpoints ← Private subnets (443)

- **IAM Roles**: Task execution + task roles with S3 access policies
  - S3 GetObject on raw bucket
  - S3 PutObject on output bucket
  - Secrets Manager for database credentials

## Deployment Instructions

### 1. Prerequisites
```bash
# Ensure Terraform is installed (v1.0+)
terraform version

# Configure AWS credentials
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
# OR use: aws configure
```

### 2. Configure Variables
Edit `terraform/terraform.tfvars`:
```hcl
aws_region  = "us-east-1"              # Change region if needed
environment = "prod"                   # dev/staging/prod
project_name = "aws-slm-app"           # Your project name

# Database password - CHANGE THIS!
db_password = "YourSecurePassword123!"

# Subnet CIDR ranges (adjust if 10.0.0.0/16 conflicts)
# public_subnet_cidrs = [...]
# db_subnet_cidrs = [...]
# etc.

# Fargate sizing
ollama_cpu = "2048"      # 2 vCPU
ollama_memory = "8192"   # 8 GB
ollama_desired_count = 2 # Replicas for HA
```

### 3. Validate & Plan
```bash
cd terraform

# Validate syntax
terraform validate

# See what will be created
terraform plan -out=tfplan

# Optional: Save plan to file for review
terraform show tfplan
```

### 4. Apply Configuration
```bash
# Apply the plan
terraform apply tfplan

# Or apply without saved plan (will show plan first)
terraform apply

# Get outputs
terraform output
```

### 5. Verify Deployment
```bash
# After deployment completes (~10-15 minutes):

# Check ECS cluster
aws ecs describe-clusters \
  --cluster-names aws-slm-app-cluster \
  --region us-east-1

# Check Ollama service status
aws ecs describe-services \
  --cluster aws-slm-app-cluster \
  --services aws-slm-app-ollama-service \
  --region us-east-1

# Check RDS instance
aws rds describe-db-instances \
  --db-instance-identifier aws-slm-app-postgres \
  --region us-east-1

# Check S3 buckets
aws s3 ls --region us-east-1
```

## Testing Connectivity

### From App Container to LLM Service
```bash
# Inside app container
curl http://aws-slm-app-ollama-service:11434/api/tags

# You should get:
# {"models": [...]}
```

### From App Container to RDS
```bash
# Inside app container
psql -h <rds-endpoint> -U postgres -d appdb

# Password: (from terraform.tfvars)
# Should connect successfully
```

### From App Container to S3
```bash
# Inside app container
# Write to output bucket
aws s3 cp /tmp/file.txt s3://aws-slm-app-output-<account-id>/

# Read from raw bucket
aws s3 ls s3://aws-slm-app-raw-<account-id>/
```

## Important Notes

### Security
1. **Database Password**: Currently in terraform.tfvars (plaintext). For production:
   - Use AWS Secrets Manager
   - Use TF_VAR_db_password environment variable
   - Use Terraform Cloud/Enterprise for secrets storage

2. **Database Backups**: 7-day retention configured
   - Automated daily backups at 03:00 UTC
   - Manual snapshots available anytime

3. **VPC Isolation**: Private subnets only reachable via:
   - NAT Gateway (outbound internet)
   - VPC Endpoints (AWS service access)
   - Security group rules (cross-subnet)

### Scaling & Performance

**Ollama Service**:
- Auto-scaling enabled: 1-4 replicas based on CPU/memory
- CPU target: 70%
- Memory target: 80%
- Health checks every 30s

**RDS**:
- Multi-AZ failover automatic
- Backup window: 03:00-04:00 UTC
- Maintenance window: Monday 04:00-05:00 UTC

**Network**:
- VPC Endpoints reduce NAT data transfer costs
- S3 gateway endpoint: free (no data charges)
- Interface endpoints: $7/month each + data

### Cost Optimization
- **NAT Gateway**: ~$32/month + $0.045/GB transfer
- **RDS Multi-AZ**: ~$150/month (db.t3.medium)
- **Fargate**: ~$0.04/vCPU-hour + $0.00441/GB-hour
- **S3**: Standard pricing ($0.023/GB first 50TB/month)

## Modification & Maintenance

### Add New S3 Bucket
```hcl
# In terraform.tfvars
s3_bucket_names = ["raw", "output", "wiki", "new-bucket"]

# Apply
terraform apply
```

### Scale Ollama Replicas
```hcl
# In terraform.tfvars
ollama_desired_count = 4  # Increase from 2

# Apply
terraform apply
```

### Increase RDS Storage
```hcl
# In terraform.tfvars
db_allocated_storage = 50  # Increase from 20

# Apply (requires ~5 minute maintenance window)
terraform apply
```

### Change Database Version
```hcl
# In terraform.tfvars
db_engine_version = "16.0"  # Update from 15.3

# Apply (requires maintenance window)
terraform apply
```

## Destroy Infrastructure
```bash
# To tear down everything (WARNING: deletes RDS database!)
terraform destroy

# Optionally skip destroy for RDS snapshot:
# (Modify rds/main.tf: skip_final_snapshot = true)
```

## Troubleshooting

### Fargate Tasks Failing to Start
```bash
# Check CloudWatch logs
aws logs tail /ecs/aws-slm-app-ollama-service --follow

# Verify security groups
aws ec2 describe-security-groups --region us-east-1
```

### Database Connection Issues
```bash
# Verify RDS endpoint is accessible from app subnet
aws ec2 describe-db-instances --region us-east-1

# Check RDS security group
aws ec2 describe-security-groups --group-ids sg-xxxxx
```

### S3 Access Denied
```bash
# Verify IAM task role has permissions
aws iam get-role-policy \
  --role-name aws-slm-app-ecs-task-role-xxxxx \
  --policy-name aws-slm-app-s3-access-xxxxx
```

## Next Steps

1. **Initialize Terraform**: `cd terraform && terraform init` ✓ (Done)
2. **Configure Variables**: Edit `terraform.tfvars` with your values
3. **Review Plan**: `terraform plan` to see what will be created
4. **Deploy**: `terraform apply tfplan` to create infrastructure
5. **Verify**: Test connectivity between components
6. **Deploy Applications**: Deploy your app containers to app_subnet

## Files Created

- Root config: 6 files (aws_provider.tf, main.tf, variables.tf, terraform.tfvars, outputs.tf, .gitignore)
- 10 modules: vpc, nat_gateway, private_subnets, security_groups, vpc_endpoints, s3, rds, iam, ecs_cluster, ollama_fargate
- Each module: 3 files (main.tf, variables.tf, outputs.tf)

**Total**: 36 Terraform files, fully validated ✓

## References

- [Terraform AWS Provider Docs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Plan stored at](./../.claude/plans/mighty-inventing-bear.md)
