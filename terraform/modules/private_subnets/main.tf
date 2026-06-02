# Database Subnets
resource "aws_subnet" "db" {
  count             = length(var.db_subnet_cidrs)
  vpc_id            = var.vpc_id
  cidr_block        = var.db_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-db-subnet-${count.index + 1}"
      Type = "Database"
    }
  )
}

# LLM Subnets
resource "aws_subnet" "llm" {
  count             = length(var.llm_subnet_cidrs)
  vpc_id            = var.vpc_id
  cidr_block        = var.llm_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-llm-subnet-${count.index + 1}"
      Type = "LLM"
    }
  )
}

# Application Subnets
resource "aws_subnet" "app" {
  count             = length(var.app_subnet_cidrs)
  vpc_id            = var.vpc_id
  cidr_block        = var.app_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-app-subnet-${count.index + 1}"
      Type = "Application"
    }
  )
}

# Frontend Subnets
resource "aws_subnet" "frontend" {
  count             = length(var.frontend_subnet_cidrs)
  vpc_id            = var.vpc_id
  cidr_block        = var.frontend_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-frontend-subnet-${count.index + 1}"
      Type = "Frontend"
    }
  )
}

# Route Tables for private subnets - each subnet type gets its own route table
# This allows for fine-grained route control if needed in the future

resource "aws_route_table" "db" {
  vpc_id = var.vpc_id

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-db-rt"
    }
  )
}

resource "aws_route_table" "llm" {
  vpc_id = var.vpc_id

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-llm-rt"
    }
  )
}

resource "aws_route_table" "app" {
  vpc_id = var.vpc_id

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-app-rt"
    }
  )
}

resource "aws_route_table" "frontend" {
  vpc_id = var.vpc_id

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-frontend-rt"
    }
  )
}

# Routes through NAT Gateways
resource "aws_route" "db_nat" {
  count                  = length(var.db_subnet_cidrs) > 0 && length(var.nat_gateway_ids) > 0 ? 1 : 0
  route_table_id         = aws_route_table.db.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.nat_gateway_ids[0]
}

resource "aws_route" "llm_nat" {
  count                  = length(var.llm_subnet_cidrs) > 0 && length(var.nat_gateway_ids) > 0 ? 1 : 0
  route_table_id         = aws_route_table.llm.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.nat_gateway_ids[0]
}

resource "aws_route" "app_nat" {
  count                  = length(var.app_subnet_cidrs) > 0 && length(var.nat_gateway_ids) > 0 ? 1 : 0
  route_table_id         = aws_route_table.app.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.nat_gateway_ids[0]
}

resource "aws_route" "frontend_nat" {
  count                  = length(var.frontend_subnet_cidrs) > 0 && length(var.nat_gateway_ids) > 0 ? 1 : 0
  route_table_id         = aws_route_table.frontend.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.nat_gateway_ids[0]
}

# Route Table Associations
resource "aws_route_table_association" "db" {
  count          = length(aws_subnet.db)
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}

resource "aws_route_table_association" "llm" {
  count          = length(aws_subnet.llm)
  subnet_id      = aws_subnet.llm[count.index].id
  route_table_id = aws_route_table.llm.id
}

resource "aws_route_table_association" "app" {
  count          = length(aws_subnet.app)
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app.id
}

resource "aws_route_table_association" "frontend" {
  count          = length(aws_subnet.frontend)
  subnet_id      = aws_subnet.frontend[count.index].id
  route_table_id = aws_route_table.frontend.id
}
