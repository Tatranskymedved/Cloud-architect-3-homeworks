# ── VPC ────────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${var.project_name}-vpc" })
}

# ── Public subnets (ALB requires subnets in ≥ 2 AZs) ─────────────────────────
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.10.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false

  tags = merge(var.tags, { Name = "${var.project_name}-subnet-public-a" })
}

resource "aws_subnet" "public_c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.10.3.0/24"
  availability_zone       = "${var.aws_region}c"
  map_public_ip_on_launch = false

  tags = merge(var.tags, { Name = "${var.project_name}-subnet-public-c" })
}

# ── Private subnets (ECS Fargate backends — no public IPs) ────────────────────
resource "aws_subnet" "private_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.10.2.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false

  tags = merge(var.tags, { Name = "${var.project_name}-subnet-private-a" })
}

resource "aws_subnet" "private_c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.10.4.0/24"
  availability_zone       = "${var.aws_region}c"
  map_public_ip_on_launch = false

  tags = merge(var.tags, { Name = "${var.project_name}-subnet-private-c" })
}

# ── Internet Gateway ───────────────────────────────────────────────────────────
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, { Name = "${var.project_name}-igw" })
}

# ── Elastic IP for NAT Gateway ─────────────────────────────────────────────────
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(var.tags, { Name = "${var.project_name}-nat-eip" })

  depends_on = [aws_internet_gateway.main]
}

# ── NAT Gateway ────────────────────────────────────────────────────────────────
# Single NAT GW in public-a — sufficient for exercise.
# ECS Fargate tasks in private subnets use NAT GW to pull container images.
# Cost: ~$0.045/hour — always run terraform destroy when done.
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id

  tags = merge(var.tags, { Name = "${var.project_name}-nat-gw" })

  depends_on = [aws_internet_gateway.main]
}

# ── Route table: public subnets → Internet Gateway ────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, { Name = "${var.project_name}-rt-public" })
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_c" {
  subnet_id      = aws_subnet.public_c.id
  route_table_id = aws_route_table.public.id
}

# ── Route table: private subnets → NAT Gateway ────────────────────────────────
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(var.tags, { Name = "${var.project_name}-rt-private" })
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_c" {
  subnet_id      = aws_subnet.private_c.id
  route_table_id = aws_route_table.private.id
}

# ── Security Group: ALB ────────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-sg-alb"
  description = "Security group for the Application Load Balancer"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound (to ECS tasks)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.project_name}-sg-alb" })
}

# ── Security Group: ECS backend tasks ─────────────────────────────────────────
# Allows port 8080 only from the ALB SG — more precise than a CIDR-based rule.
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project_name}-sg-ecs-tasks"
  description = "Allow HTTP 8080 from ALB SG only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP 8080 from ALB security group only"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "All outbound (image pull via NAT GW, CloudWatch logs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.project_name}-sg-ecs-tasks" })
}
