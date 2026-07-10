locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = merge(var.tags, {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  })

  # 1 NAT for dev (cost-optimized, documented single-AZ-egress risk),
  # 1 per AZ for prod (full AZ independence for egress traffic).
  nat_gateway_count = var.single_nat_gateway ? 1 : length(var.availability_zones)
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required for private DNS resolution (e.g. RDS endpoint, VPC endpoints)

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-igw"
  })
}

# ---------------------------------------------------------------------------
# Subnets — 3 tiers x 2 AZs = 6 subnets
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true # ALB ENIs and NAT Gateways need public IPs

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-${var.availability_zones[count.index]}"
    Tier = "public"
  })
}

resource "aws_subnet" "private_app" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_app_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  # map_public_ip_on_launch intentionally omitted (defaults false) — ECS tasks
  # must never receive a public IP; the ALB is the only internet-facing hop.

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-app-${var.availability_zones[count.index]}"
    Tier = "private-app"
  })
}

resource "aws_subnet" "private_data" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_data_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-data-${var.availability_zones[count.index]}"
    Tier = "private-data"
  })
}

# ---------------------------------------------------------------------------
# NAT Gateway(s) — live in public subnets, give private-app subnets egress
# ---------------------------------------------------------------------------
resource "aws_eip" "nat" {
  count  = local.nat_gateway_count
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat-eip-${count.index}"
  })
}

resource "aws_nat_gateway" "main" {
  count         = local.nat_gateway_count
  allocation_id = aws_eip.nat[count.index].id
  # When single_nat_gateway = true, this always lands in AZ index 0.
  # When false, one NAT per AZ, placed in that AZ's own public subnet —
  # this is what gives prod its per-AZ egress independence.
  subnet_id = aws_subnet.public[count.index].id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat-${count.index}"
  })

  depends_on = [aws_internet_gateway.main]
}

# ---------------------------------------------------------------------------
# Route tables
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private-app route table per AZ, so each AZ's egress goes through its
# *own local* NAT when we have one-per-AZ (no cross-AZ data transfer charges),
# and both point at the single NAT when single_nat_gateway = true.
resource "aws_route_table" "private_app" {
  count  = length(var.availability_zones)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.main[0].id : aws_nat_gateway.main[count.index].id
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-app-rt-${var.availability_zones[count.index]}"
  })
}

resource "aws_route_table_association" "private_app" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app[count.index].id
}

# Private-data route table: deliberately NO 0.0.0.0/0 route at all.
# RDS has no path to or from the internet, in either direction, at the
# network layer — independent of whatever the RDS security group says.
resource "aws_route_table" "private_data" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-data-rt"
  })
}

resource "aws_route_table_association" "private_data" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.private_data[count.index].id
  route_table_id = aws_route_table.private_data.id
}
