locals {
  # Merge default tags with user-provided tags
  merged_tags = merge(
    var.tags,
    {
      Environment = var.environment
      Project     = var.project_name
    }
  )
}

# VPC Module
module "vpc" {
  source = "./modules/vpc"

  vpc_cidr              = var.vpc_cidr
  project_name          = var.project_name
  environment           = var.environment
  public_subnet_cidrs   = var.public_subnet_cidrs
  availability_zones    = var.availability_zones

  tags = local.merged_tags
}

# NAT Gateway Module
module "nat_gateway" {
  source = "./modules/nat_gateway"

  public_subnet_ids   = module.vpc.public_subnet_ids
  availability_zones  = var.availability_zones
  project_name        = var.project_name
  environment         = var.environment
  enable_nat_gateway  = var.enable_nat_gateway

  tags = local.merged_tags

  depends_on = [module.vpc]
}

# Private Subnets Module
module "private_subnets" {
  source = "./modules/private_subnets"

  vpc_id              = module.vpc.vpc_id
  availability_zones  = var.availability_zones
  db_subnet_cidrs     = var.db_subnet_cidrs
  llm_subnet_cidrs    = var.llm_subnet_cidrs
  app_subnet_cidrs    = var.app_subnet_cidrs
  frontend_subnet_cidrs = var.frontend_subnet_cidrs
  nat_gateway_ids     = module.nat_gateway.nat_gateway_ids
  project_name        = var.project_name
  environment         = var.environment

  tags = local.merged_tags

  depends_on = [module.nat_gateway]
}

# Security Groups Module
module "security_groups" {
  source = "./modules/security_groups"

  vpc_id           = module.vpc.vpc_id
  project_name     = var.project_name
  environment      = var.environment
  ollama_port      = var.ollama_container_port

  tags = local.merged_tags

  depends_on = [module.vpc]
}

# VPC Endpoints Module
module "vpc_endpoints" {
  source = "./modules/vpc_endpoints"

  vpc_id                        = module.vpc.vpc_id
  vpc_cidr                      = var.vpc_cidr
  private_subnet_ids            = concat(
    module.private_subnets.db_subnet_ids,
    module.private_subnets.llm_subnet_ids,
    module.private_subnets.app_subnet_ids,
    module.private_subnets.frontend_subnet_ids
  )
  route_table_ids               = concat(
    module.private_subnets.db_route_table_ids,
    module.private_subnets.llm_route_table_ids,
    module.private_subnets.app_route_table_ids,
    module.private_subnets.frontend_route_table_ids
  )
  vpc_endpoint_security_group_id = module.security_groups.vpc_endpoint_sg_id
  project_name                  = var.project_name
  environment                   = var.environment

  tags = local.merged_tags

  depends_on = [module.private_subnets, module.security_groups]
}

# S3 Module
# vpc_id is used only for bucket policy conditions (extra Allow, not a Deny).
# EC2/ECS access is controlled by IAM roles — S3 works regardless of this value.
# For dev: set s3_vpc_id to your default VPC ID in terraform.tfvars.
# For prod: set s3_vpc_id to the custom VPC ID after the vpc module is applied.
module "s3" {
  source = "./modules/s3"

  bucket_names             = var.s3_bucket_names
  enable_versioning        = var.s3_enable_versioning
  enable_encryption        = var.s3_enable_encryption
  vpc_id                   = var.s3_vpc_id
  app_subnet_cidr_blocks   = var.app_subnet_cidrs
  project_name             = var.project_name
  environment              = var.environment

  tags = local.merged_tags
}

# RDS Module
module "rds" {
  source = "./modules/rds"

  db_instance_class         = var.db_instance_class
  db_allocated_storage      = var.db_allocated_storage
  db_name                   = var.db_name
  db_username               = var.db_username
  db_password               = var.db_password
  db_backup_retention_days  = var.db_backup_retention_days
  db_multi_az               = var.db_multi_az
  db_engine_version         = var.db_engine_version

  subnet_ids                = module.private_subnets.db_subnet_ids
  security_group_id         = module.security_groups.rds_sg_id

  project_name              = var.project_name
  environment               = var.environment

  tags = local.merged_tags

  depends_on = [module.private_subnets, module.security_groups]
}

# IAM Module
module "iam" {
  source = "./modules/iam"

  raw_bucket_arn    = module.s3.raw_bucket_arn
  output_bucket_arn = module.s3.output_bucket_arn
  project_name      = var.project_name
  environment       = var.environment

  tags = local.merged_tags

  depends_on = [module.s3]
}

# ECS Cluster Module
module "ecs_cluster" {
  source = "./modules/ecs_cluster"

  project_name = var.project_name
  environment  = var.environment

  tags = local.merged_tags
}

# Dev EC2 Module — local Python + SSH tunnel workflow
# Set enable_dev_ec2 = true in terraform.tfvars to create.
# Destroy with: terraform destroy -target=module.ec2_dev
module "ec2_dev" {
  count  = var.enable_dev_ec2 ? 1 : 0
  source = "./modules/ec2_dev"

  project_name      = var.project_name
  environment       = var.environment
  instance_type     = var.dev_ec2_instance
  key_name          = var.dev_ec2_key_name
  ssh_public_key    = var.dev_ssh_public_key
  ollama_model      = var.ollama_model
  raw_bucket_arn    = module.s3.raw_bucket_arn
  output_bucket_arn = module.s3.output_bucket_arn

  tags = local.merged_tags

  depends_on = [module.s3]
}

# Ollama Fargate Module
module "ollama_fargate" {
  source = "./modules/ollama_fargate"

  ecs_cluster_name          = module.ecs_cluster.cluster_name
  ecs_cluster_arn           = module.ecs_cluster.cluster_arn

  subnets                   = module.private_subnets.llm_subnet_ids
  security_group_id         = module.security_groups.llm_sg_id

  container_image           = var.ollama_container_image
  container_port            = var.ollama_container_port
  container_cpu             = var.ollama_cpu
  container_memory          = var.ollama_memory

  model                     = var.ollama_model
  desired_count             = var.ollama_desired_count

  cloudwatch_log_group      = module.ecs_cluster.log_group_name
  task_execution_role_arn   = module.iam.ecs_task_execution_role_arn
  task_role_arn             = module.iam.ecs_task_role_arn

  project_name              = var.project_name
  environment               = var.environment

  tags = local.merged_tags

  depends_on = [module.ecs_cluster, module.security_groups, module.private_subnets, module.iam]
}
