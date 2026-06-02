# AWS SLM App Infrastructure

A production-ready Terraform infrastructure-as-code (IaC) solution for deploying a containerized Small Language Model (SLM) application on AWS with multi-tier architecture, database, and secure networking.

## Overview

This project provisions a complete AWS infrastructure featuring:

- **Multi-AZ VPC Architecture** with public and private subnets
- **Containerized Ollama SLM** deployment on AWS Fargate with auto-scaling
- **PostgreSQL Database** (RDS) with Multi-AZ failover and automated backups
- **S3 Data Pipeline** for raw data ingestion and processed output storage
- **Secure Networking** with NAT Gateways, security groups, and VPC endpoints
- **IAM Policies** for fine-grained access control between application tiers

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Internet                              │
└────────────┬────────────────────────────────────┬────────────┘
             │                                    │
      ┌──────▼──────┐                      ┌──────▼──────┐
      │  NAT GW AZ1 │                      │  NAT GW AZ2 │
      └──────┬──────┘                      └──────┬──────┘
             │                                    │
      ┌──────▼──────────────────────────────────┐ │
      │   VPC: 10.0.0.0/16                     │ │
      │                                        │ │
      │  ┌─ Frontend Subnet (AZ1, AZ2)        │ │
      │  │  - Frontend containers             │ │
      │  │                                    │ │
      │  ├─ App Subnet (AZ1, AZ2)             │ │
      │  │  - Application containers          │ │
      │  │  - S3 access (raw, output)         │ │
      │  │  - Database access                 │ │
      │  │  - LLM API access                  │ │
      │  │                                    │ │
      │  ├─ LLM Subnet (AZ1, AZ2)             │ │
      │  │  - Ollama Fargate tasks            │ │
      │  │  - Model serving (port 11434)      │ │
      │  │  - Auto-scaling (1-4 replicas)     │ │
      │  │                                    │ │
      │  ├─ Database Subnet (AZ1, AZ2)        │ │
      │  │  - RDS PostgreSQL Multi-AZ         │ │
      │  │  - Encrypted, automated backups    │ │
      │  │                                    │ │
      │  └─ S3 Buckets                        │ │
      │     - raw (data ingestion)            │ │
      │     - output (processed results)      │ │
      │     - wiki (knowledge base)           │ │
      │                                        │ │
      └────────────────────────────────────────┘ │
             └────────────────────────────────────┘
```

## Detailed Architecture

We use AWS ECS Fargate and RDS to run our SLM application securely. 

[👉 Click here to view the full Architecture Diagram](architecture.md)

## Prerequisites

- **Terraform**: v1.0 or later ([install](https://learn.hashicorp.com/tutorials/terraform/install-cli))
- **AWS Account**: With appropriate permissions to create VPC, EC2, RDS, S3, ECS resources
- **AWS CLI**: v2 (optional, for verification commands)
- **Git**: For version control

## Quick Start

### 1. Clone & Navigate to Project
```bash
git clone <repo-url>
cd aws-slm-app-infra
```

### 2. Configure AWS Credentials
```bash
# Option A: Environment variables
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_DEFAULT_REGION="us-east-1"

# Option B: AWS CLI
aws configure

# Option C: AWS SSO
aws sso login --profile your-profile
export AWS_PROFILE=your-profile
```

### 3. Customize Configuration
```bash
cd terraform
cp terraform.tfvars terraform.tfvars.bak  # Backup original
nano terraform.tfvars                     # Edit values
```

Key variables to update:
- `aws_region`: AWS region (default: us-east-1)
- `environment`: dev/staging/prod (default: prod)
- `project_name`: Your project identifier (default: aws-slm-app)
- `db_password`: Strong password for PostgreSQL
- `ollama_desired_count`: Number of replicas (default: 2)

### 4. Initialize Terraform
```bash
terraform init
```

### 5. Review & Deploy
```bash
# Preview changes
terraform plan -out=tfplan

# Apply configuration
terraform apply tfplan

# Get outputs (connection details)
terraform output
```

The deployment takes approximately **10-15 minutes**.

## Directory Structure

```
.
├── README.md                          # This file
├── TERRAFORM_SETUP.md                 # Detailed setup guide
├── .gitignore                         # Git ignores
│
└── terraform/
    ├── aws_provider.tf               # AWS provider config
    ├── main.tf                       # Root module composition
    ├── variables.tf                  # Input variable definitions
    ├── terraform.tfvars              # Variable values (CHANGE THIS)
    ├── outputs.tf                    # Output definitions
    │
    └── modules/
        ├── vpc/                      # VPC + IGW + public subnets
        ├── nat_gateway/              # NAT Gateways (HA)
        ├── private_subnets/          # 8 private subnets
        ├── security_groups/          # Security group rules
        ├── vpc_endpoints/            # VPC endpoints (S3, ECR, etc)
        ├── s3/                       # S3 buckets + policies
        ├── rds/                      # PostgreSQL RDS instance
        ├── iam/                      # IAM roles + policies
        ├── ecs_cluster/              # ECS cluster setup
        └── ollama_fargate/           # Ollama Fargate service
```

## Infrastructure Components

### Network
| Component | Details |
|-----------|---------|
| **VPC** | 10.0.0.0/16 with DNS enabled |
| **Public Subnets** | 2 (one per AZ) for NAT Gateways |
| **Private Subnets** | 8 total: 2 each for db, llm, app, frontend |
| **NAT Gateways** | 2 (HA across AZs) |
| **VPC Endpoints** | S3, ECR API, ECR DKR, CloudWatch Logs, Secrets Manager |

### Compute
| Component | Details |
|-----------|---------|
| **ECS Cluster** | Fargate-only, container insights enabled |
| **Ollama Service** | 2 replicas, auto-scaling 1-4 based on CPU/memory |
| **Container CPU** | 2 vCPU (configurable) |
| **Container Memory** | 8 GB (configurable) |
| **Model** | llama2 (configurable) |

### Data Storage
| Component | Details |
|-----------|---------|
| **RDS Database** | PostgreSQL 15.3, Multi-AZ, encrypted |
| **Database Size** | db.t3.medium, 20 GB storage (configurable) |
| **Backups** | Daily, 7-day retention (configurable) |
| **S3 Buckets** | raw, output, wiki (versioned & encrypted) |

### Security
| Component | Details |
|-----------|---------|
| **Security Groups** | Layered: frontend → app → llm/rds |
| **IAM Roles** | Task execution + task roles with S3/Secrets access |
| **Encryption** | RDS (KMS), S3 (AES256), TLS for endpoints |
| **Network Isolation** | Private subnets, no direct internet except NAT |

## Usage

### Deploy Infrastructure
```bash
cd terraform
terraform plan -out=tfplan
terraform apply tfplan
```

### Get Connection Details
```bash
terraform output

# Sample outputs:
# rds_endpoint = "aws-slm-app-postgres.xxxxx.us-east-1.rds.amazonaws.com:5432"
# ollama_internal_endpoint = "aws-slm-app-ollama-service"
# s3_bucket_names = { raw = "aws-slm-app-raw-123456", ... }
```

### Deploy Application Containers
```bash
# Create ECS task definition for your app
aws ecs register-task-definition \
  --cli-input-json file://app-task-definition.json

# Launch service
aws ecs create-service \
  --cluster aws-slm-app-cluster \
  --service-name my-app-service \
  --task-definition my-app:1 \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[<app-subnet-ids>],securityGroups=[<app-sg-id>]}"
```

### Test Connectivity
```bash
# From within app container:

# 1. Test LLM API
curl http://aws-slm-app-ollama-service:11434/api/tags

# 2. Test Database
psql -h <rds-endpoint> -U postgres -d appdb

# 3. Test S3 Read/Write
aws s3 ls s3://aws-slm-app-raw-<account-id>/
aws s3 cp /tmp/file.txt s3://aws-slm-app-output-<account-id>/
```

### Scale Ollama Replicas
```bash
# Update terraform.tfvars
ollama_desired_count = 4

# Apply changes
terraform apply -auto-approve
```

### Increase Database Size
```bash
# Update terraform.tfvars
db_allocated_storage = 50

# Apply changes (causes brief maintenance window)
terraform apply -auto-approve
```

### Destroy Infrastructure
```bash
# WARNING: This will delete the RDS database!
terraform destroy

# Confirm when prompted
```

## Configuration Reference

### Required Variables
- `db_password`: Master password for PostgreSQL (min 8 chars)

### Common Variables
```hcl
aws_region                = "us-east-1"
environment               = "prod"
project_name              = "aws-slm-app"
vpc_cidr                  = "10.0.0.0/16"
availability_zones        = ["us-east-1a", "us-east-1b"]

db_instance_class         = "db.t3.medium"
db_allocated_storage      = 20

ollama_cpu                = "2048"      # 2 vCPU
ollama_memory             = "8192"      # 8 GB
ollama_desired_count      = 2
ollama_model              = "llama2"

s3_bucket_names           = ["raw", "output", "wiki"]
```

See [terraform/variables.tf](terraform/variables.tf) for all available options.

## Cost Estimation

**Monthly costs (approximate)**:
- NAT Gateways: $32 + data transfer
- RDS (db.t3.medium, Multi-AZ): $150-200
- Fargate (2 × 2vCPU, 8GB): $60-80
- S3: Variable (~$0.023/GB for first 50TB)
- ECS: Free
- VPC Endpoints: ~$7 each (S3 endpoint is free)

**Total**: ~$250-350/month for production baseline

## Monitoring & Logs

### CloudWatch Logs
```bash
# View Ollama logs
aws logs tail /ecs/aws-slm-app-ollama-service --follow

# View RDS activity
aws logs tail /aws/rds/instance/aws-slm-app-postgres/error --follow
```

### CloudWatch Metrics
- Access via AWS Console > CloudWatch
- Monitor: ECS CPU/Memory, RDS connections, NAT Gateway traffic

### Health Checks
- Ollama service: HTTP health check on port 11434 every 30s
- RDS: AWS managed failover detection
- Fargate: Task count and running tasks

## Troubleshooting

### Fargate Tasks Failing
```bash
# Check task logs
aws logs tail /ecs/aws-slm-app-ollama-service --follow

# Describe service
aws ecs describe-services \
  --cluster aws-slm-app-cluster \
  --services aws-slm-app-ollama-service
```

### Database Connection Issues
```bash
# Verify RDS is accessible
aws ec2 describe-security-groups \
  --group-ids <rds-sg-id>

# Test connectivity from bastion/EC2
psql -h <rds-endpoint> -U postgres -d appdb
```

### S3 Access Denied
```bash
# Verify IAM role permissions
aws iam get-role-policy \
  --role-name aws-slm-app-ecs-task-role-* \
  --policy-name aws-slm-app-s3-access-*
```

For more detailed troubleshooting, see [TERRAFORM_SETUP.md](TERRAFORM_SETUP.md#troubleshooting).

## Security Best Practices

1. **Database Password**: Don't commit to Git
   - Use environment variables: `export TF_VAR_db_password="..."`
   - Or use AWS Secrets Manager integration

2. **State Management**: Terraform state contains sensitive data
   - Use S3 backend with encryption: [TERRAFORM_SETUP.md](TERRAFORM_SETUP.md#state-management)
   - Enable MFA for state modifications

3. **IAM Access**: Restrict who can modify infrastructure
   - Use IAM policies to limit `terraform apply` access
   - Enable CloudTrail for audit logging

4. **Network Security**: Review security groups regularly
   - No unnecessary open ports
   - Use security group references instead of CIDR blocks where possible

5. **Encryption**: All data at rest is encrypted
   - RDS: AWS KMS
   - S3: AES256
   - Add TLS certificates for app endpoints

## Support & Issues

### Report Issues
- GitHub Issues: [Create an issue](../../issues/new)
- Email: [support@example.com]

### Common Questions

**Q: Can I change the region?**
A: Yes, update `aws_region` in terraform.tfvars

**Q: How do I add a new subnet type?**
A: Duplicate a subnet type in `modules/private_subnets/main.tf` and update variables

**Q: How do I enable read replicas for RDS?**
A: Add `read_replica_identifier` to `modules/rds/main.tf`

**Q: Can I use spot instances instead of Fargate?**
A: Yes, modify `modules/ollama_fargate/main.tf` to use EC2 launch type with spot pricing

## Contributing

1. Create a feature branch: `git checkout -b feature/your-feature`
2. Make changes and test locally
3. Commit: `git commit -am 'Add feature'`
4. Push: `git push origin feature/your-feature`
5. Submit pull request

## License

[Specify your license here - e.g., MIT, Apache 2.0]

## Related Documentation

- [Detailed Setup Guide](TERRAFORM_SETUP.md)
- [Architecture Plan](./.claude/plans/mighty-inventing-bear.md)
- [AWS VPC Documentation](https://docs.aws.amazon.com/vpc/)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest)
- [Ollama Documentation](https://github.com/ollama/ollama)

## Changelog

### v1.0.0 (2026-06-01)
- Initial release
- VPC with 8 private subnets across 2 AZs
- Multi-AZ RDS PostgreSQL
- Fargate-based Ollama deployment
- S3 data pipeline buckets
- Complete IAM and security group configuration
- VPC endpoints for cost optimization

---

**Made with Terraform** | **AWS Infrastructure** | **Ollama SLM**

For questions or support, please refer to the [TERRAFORM_SETUP.md](TERRAFORM_SETUP.md) guide.
