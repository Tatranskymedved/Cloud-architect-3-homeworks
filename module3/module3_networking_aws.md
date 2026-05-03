# AWS Implementation — Module 3: Networking (Versioned API with Traffic Splitting)

---

## AWS service mapping

| Homework component | AWS service | Type / config | Rationale |
|---|---|---|---|
| Virtual network | `aws_vpc` | CIDR 10.10.0.0/16 | AWS VPC; free to create — billed by NAT Gateway and data transfer |
| Public subnet (load balancer) | `aws_subnet` (×2) | `map_public_ip_on_launch = false`; route table → IGW | ALB requires subnets in ≥ 2 Availability Zones; public subnets in eu-west-1a and eu-west-1c |
| Private subnet (backends) | `aws_subnet` (×2) | `map_public_ip_on_launch = false`; route table → NAT GW | ECS Fargate tasks with no public IP; two private subnets for multi-AZ placement |
| Internet Gateway | `aws_internet_gateway` | attached to VPC | Enables public subnets to receive inbound traffic; required for NAT Gateway |
| NAT Gateway | `aws_nat_gateway` | single NAT in public-a subnet, Elastic IP attached | Allows ECS Fargate in private subnets to pull container images from public registries; outbound-only |
| Network security (NSG equivalent) | `aws_security_group` (×2) | one for ALB, one for ECS tasks | Stateful; ECS SG allows 8080 only from ALB SG (referenced by ID, not CIDR) |
| L7 Application Load Balancer | `aws_lb` | `type = "application"`, internet-facing | HTTP/HTTPS termination; path-based and weighted routing; spans two public subnets |
| HTTPS listener (port 443) | `aws_lb_listener` | `protocol = HTTPS`, `port = 443` | TLS offload at ALB; certificate from ACM; default action forwards to TG v1 |
| TLS certificate | `tls_private_key` + `tls_self_signed_cert` + `aws_acm_certificate` (imported) | RSA 2048, PEM format | Self-signed acceptable for exercise; ACM import accepts PEM directly — no PFX conversion needed unlike Azure |
| Backend pool v1 | `aws_lb_target_group` | `target_type = ip`, HTTP, port 8080 | IP-type target group required for ECS Fargate; health check on `/v1/items` |
| Backend pool v2 | `aws_lb_target_group` | `target_type = ip`, HTTP, port 8080 | Same pattern; health check on `/v2/items` |
| Path rule `/v1/items*` → TG v1 | `aws_lb_listener_rule` | priority 10; `path-pattern` condition | Higher-priority rule; exact version routing |
| Path rule `/v2/items*` → TG v2 | `aws_lb_listener_rule` | priority 20; `path-pattern` condition | Higher-priority rule; exact version routing |
| Weighted canary `/items*` (90/10) | `aws_lb_listener_rule` | priority 30; `forward` with weight blocks v1=90, v2=10 | **Native AWS ALB feature** — no workaround needed unlike Azure Application Gateway |
| Backend compute v1 | `aws_ecs_cluster` + `aws_ecs_task_definition` + `aws_ecs_service` (Fargate) | Fargate; `assign_public_ip = false` | Serverless containers in private subnets; no EC2 instance management |
| Backend compute v2 | separate task definition + service in same cluster | image tag `:v2` | Shares ECS cluster with v1; separate task definition for different image |
| DNS record | `aws_route53_zone` (private) + `aws_route53_record` (alias) | Private hosted zone associated with VPC; alias → ALB DNS name | ALB has no static IP — alias record is the correct AWS DNS pattern |
| S3 VPC Endpoint (stretch) | `aws_vpc_endpoint` | `type = Gateway`; `com.amazonaws.eu-west-1.s3` | Free gateway endpoint; no ENI or hourly charge; adds S3 route to route tables |
| Storage (stretch) | `aws_s3_bucket` + `aws_s3_bucket_policy` | Block all public access; allow only via VPC endpoint | Equivalent to Azure Storage Account with `public_network_access_enabled = false` |

> **AWS advantage: native weighted routing.** Unlike Azure Application Gateway Standard_v2 — which does not support weighted routing between two different backend pools — AWS ALB natively supports weighted `forward` actions in `aws_lb_listener_rule`. The 90/10 canary split is a single Terraform resource with two `target_group` weight blocks. No Azure Front Door, Container Apps, or sidecar proxy is needed.

---

## Architecture

```
Internet
    │
    │  HTTPS :443
    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  AWS Account / Region: eu-west-1                                         │
│                                                                          │
│  ┌───────────────────────────────────────────────────────────────────┐   │
│  │  VPC: 10.10.0.0/16                                                │   │
│  │                                                                   │   │
│  │  ┌────────────────────┐  ┌────────────────────┐                  │   │
│  │  │ subnet-public-a    │  │ subnet-public-c    │                  │   │
│  │  │ 10.10.1.0/24       │  │ 10.10.3.0/24       │                  │   │
│  │  │ eu-west-1a → IGW   │  │ eu-west-1c → IGW   │                  │   │
│  │  │                    │  │                    │                  │   │
│  │  │  NAT GW (EIP)      │  │                    │                  │   │
│  │  │                    │  │                    │                  │   │
│  │  │  ┌─────────────────┴──┴──────────────────┐ │                  │   │
│  │  │  │  ALB (internet-facing)                 │ │                  │   │
│  │  │  │  SG: allow HTTPS 443 from 0.0.0.0/0   │ │                  │   │
│  │  │  │                                        │ │                  │   │
│  │  │  │  HTTPS Listener :443 (TLS offload)     │ │                  │   │
│  │  │  │    ├─ Rule p10: /v1/items* → TG v1     │ │                  │   │
│  │  │  │    ├─ Rule p20: /v2/items* → TG v2     │ │                  │   │
│  │  │  │    ├─ Rule p30: /items*   → weighted   │ │                  │   │
│  │  │  │    │       v1: weight 90               │ │                  │   │
│  │  │  │    │       v2: weight 10               │ │                  │   │
│  │  │  │    └─ Default: → TG v1                 │ │                  │   │
│  │  │  │                                        │ │                  │   │
│  │  │  │  Backend: HTTP :8080 (TLS offloaded)   │ │                  │   │
│  │  │  └────────────────────────────────────────┘ │                  │   │
│  │  └────────────────────┘  └────────────────────┘                  │   │
│  │                                                                   │   │
│  │  ┌────────────────────┐  ┌────────────────────┐                  │   │
│  │  │ subnet-private-a   │  │ subnet-private-c   │                  │   │
│  │  │ 10.10.2.0/24       │  │ 10.10.4.0/24       │                  │   │
│  │  │ eu-west-1a → NAT   │  │ eu-west-1c → NAT   │                  │   │
│  │  │                    │  │                    │                  │   │
│  │  │  ECS Fargate v1         ECS Fargate v2                        │   │
│  │  │  Task: HTTP :8080        Task: HTTP :8080                      │   │
│  │  │  No public IP            No public IP                          │   │
│  │  │  SG: allow 8080 from ALB SG only                               │   │
│  │  │                                                               │   │
│  │  │  (Stretch) S3 VPC Gateway Endpoint                            │   │
│  │  │  → routes *.s3.amazonaws.com through VPC (free)               │   │
│  │  └────────────────────┘  └────────────────────┘                  │   │
│  └───────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  Route53 Private Hosted Zone: module3.example.local                      │
│    Alias A record: api → ALB DNS name                                    │
│    (Resolves only inside the VPC)                                        │
└──────────────────────────────────────────────────────────────────────────┘

ACM Certificate (imported self-signed PEM)
  ↑ used by ALB HTTPS listener
```

---

## Terraform file structure

```
homeworks/module3/terraform_aws/
├── main.tf              # AWS + TLS provider config
├── network.tf           # VPC, subnets, IGW, NAT GW, route tables, security groups
├── alb.tf               # Self-signed cert → ACM, ALB, target groups, listener, listener rules
├── backends.tf          # IAM role, CloudWatch log groups, ECS cluster, task defs, services
├── dns.tf               # Route53 private hosted zone + alias A record
├── vpc_endpoint.tf      # S3 VPC Gateway Endpoint + S3 bucket (stretch goal)
├── variables.tf         # Input variable declarations
├── outputs.tf           # Output values
└── terraform.tfvars     # Concrete values — add to .gitignore
```

---

## Terraform resources

### `main.tf`

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Authentication — set environment variables before running terraform commands:
  #   $env:AWS_ACCESS_KEY_ID     = "AKIA..."
  #   $env:AWS_SECRET_ACCESS_KEY = "your-secret-key"
  #   $env:AWS_DEFAULT_REGION    = "eu-west-1"
  # Or use a named profile:
  #   $env:AWS_PROFILE = "module3"
  # Or AWS SSO:
  #   aws sso login --profile module3
  #   $env:AWS_PROFILE = "module3"
}
```

> There is no AWS equivalent of an Azure Resource Group. AWS resources are organized by region, VPC, and tags. All resources in this module use the `tags` variable for consistent labelling.

---

### `variables.tf`

```hcl
variable "aws_region" {
  type        = string
  default     = "eu-west-1"
  description = "AWS region. eu-west-1 (Ireland) is nearest to Czech Republic."
}

variable "project_name" {
  type        = string
  default     = "module3-networking"
  description = "Prefix applied to all resource names."
}

variable "api_image_v1" {
  type        = string
  description = "Container image URI for API v1. Example: public.ecr.aws/<alias>/lesson03-api-v1:latest"
}

variable "api_image_v2" {
  type        = string
  description = "Container image URI for API v2. Example: public.ecr.aws/<alias>/lesson03-api-v2:latest"
}

variable "dns_zone_name" {
  type        = string
  default     = "module3.example.local"
  description = "Route53 private hosted zone name."
}

variable "tags" {
  type = map(string)
  default = {
    project     = "module3-networking"
    environment = "dev"
    managed_by  = "terraform"
  }
  description = "Tags applied to all resources."
}
```

---

### `terraform.tfvars`

```hcl
aws_region    = "eu-west-1"
project_name  = "module3-networking"
api_image_v1  = "public.ecr.aws/<your-ecr-alias>/lesson03-api-v1:latest"   # replace <your-ecr-alias>
api_image_v2  = "public.ecr.aws/<your-ecr-alias>/lesson03-api-v2:latest"   # replace <your-ecr-alias>
dns_zone_name = "module3.example.local"
```

Add `terraform.tfvars` and `terraform.tfstate*` to `.gitignore` — they contain sensitive values and local state.

---

### `network.tf`

```hcl
# ── VPC ────────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true  # required for Route53 private zone resolution inside the VPC

  tags = merge(var.tags, { Name = "${var.project_name}-vpc" })
}

# ── Public subnets (ALB requires ≥ 2 AZs) ─────────────────────────────────────
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

# ── Private subnets (ECS Fargate backends) ─────────────────────────────────────
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
  domain = "vpc"  # replaces the deprecated `vpc = true` attribute in provider 5.x

  tags = merge(var.tags, { Name = "${var.project_name}-nat-eip" })

  depends_on = [aws_internet_gateway.main]
}

# ── NAT Gateway ────────────────────────────────────────────────────────────────
# Placed in public-a only (single NAT GW is sufficient and cheaper for exercise).
# ECS Fargate tasks in private subnets route outbound traffic through NAT GW
# to pull container images from ECR Public (public.ecr.aws).
# Production note: deploy one NAT GW per AZ to avoid cross-AZ data transfer charges.
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
# Allows inbound HTTPS from the internet. Allows all outbound (to ECS tasks).
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
# Allows inbound TCP 8080 ONLY from the ALB security group (by SG reference, not CIDR).
# This is more precise than subnet CIDR rules: if the ALB subnets change, this rule
# remains correct. All other inbound traffic is denied by default (AWS SG default-deny).
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
    description = "All outbound (ECR Public image pull via NAT GW, CloudWatch logs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.project_name}-sg-ecs-tasks" })
}
```

> **Security Groups vs Azure NSGs:** AWS Security Groups are attached to resources (network interfaces), not subnets. The "subnet-level" enforcement is achieved by attaching the same SG to all tasks in private subnets. SG ingress rules can reference another SG by ID (`security_groups = [sg-id]`), which is more precise than CIDR rules — this is why `ecs_tasks` SG references `alb` SG directly. No explicit deny rules are needed; AWS SGs have an implicit default-deny for all unmatched traffic.

---

### `alb.tf`

```hcl
# ── Self-signed TLS certificate ────────────────────────────────────────────────
resource "tls_private_key" "alb" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "alb" {
  private_key_pem = tls_private_key.alb.private_key_pem

  subject {
    common_name  = "api.${var.dns_zone_name}"
    organization = "Module3 Exercise"
  }

  validity_period_hours = 8760  # 1 year

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# ── ACM certificate import ─────────────────────────────────────────────────────
# AWS ALB requires the certificate to be in ACM. Unlike Azure Application Gateway
# which embeds a PFX binary, ALB accepts ACM-managed or ACM-imported certs only.
# Importing a PEM self-signed cert into ACM is free and requires no format conversion.
resource "aws_acm_certificate" "alb" {
  private_key       = tls_private_key.alb.private_key_pem
  certificate_body  = tls_self_signed_cert.alb.cert_pem
  certificate_chain = tls_self_signed_cert.alb.cert_pem  # self-signed: chain = cert itself

  tags = merge(var.tags, { Name = "${var.project_name}-acm-cert" })

  lifecycle {
    create_before_destroy = true
  }
}

# ── Application Load Balancer ──────────────────────────────────────────────────
resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false  # internet-facing; use true for VPC-internal ALB
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_c.id]

  tags = merge(var.tags, { Name = "${var.project_name}-alb" })
}

# ── Target Group: v1 ──────────────────────────────────────────────────────────
# target_type = "ip" is required for ECS Fargate.
# Fargate tasks use awsvpc network mode — each task gets its own ENI with an IP.
# target_type = "instance" is used only for EC2 instances registered by instance ID.
resource "aws_lb_target_group" "v1" {
  name        = "${var.project_name}-tg-v1"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/v1/items"
    protocol            = "HTTP"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = merge(var.tags, { Name = "${var.project_name}-tg-v1" })
}

# ── Target Group: v2 ──────────────────────────────────────────────────────────
resource "aws_lb_target_group" "v2" {
  name        = "${var.project_name}-tg-v2"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/v2/items"
    protocol            = "HTTP"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = merge(var.tags, { Name = "${var.project_name}-tg-v2" })
}

# ── HTTPS Listener (port 443) ─────────────────────────────────────────────────
# ssl_policy: ELBSecurityPolicy-TLS13-1-2-2021-06 supports TLS 1.2 and TLS 1.3.
# This is the recommended policy as of 2026 — it deprecates TLS 1.0 and 1.1.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.alb.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.v1.arn
  }

  tags = merge(var.tags, { Name = "${var.project_name}-listener-https" })
}

# ── Listener Rule: /v1/items* → Target Group v1 ───────────────────────────────
# Priority 10: evaluated first. Explicit version path → explicit version pool.
resource "aws_lb_listener_rule" "v1_items" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.v1.arn
  }

  condition {
    path_pattern {
      values = ["/v1/items", "/v1/items/*"]
    }
  }

  tags = merge(var.tags, { Name = "${var.project_name}-rule-v1-items" })
}

# ── Listener Rule: /v2/items* → Target Group v2 ───────────────────────────────
# Priority 20: evaluated after rule 10.
resource "aws_lb_listener_rule" "v2_items" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.v2.arn
  }

  condition {
    path_pattern {
      values = ["/v2/items", "/v2/items/*"]
    }
  }

  tags = merge(var.tags, { Name = "${var.project_name}-rule-v2-items" })
}

# ── Listener Rule: /items* → Weighted 90/10 canary split ──────────────────────
# Priority 30: evaluated after rules 10 and 20, so /v1/items and /v2/items are
# already caught and never reach this rule.
#
# The forward block with multiple target_group entries is the native AWS ALB
# weighted routing mechanism. This is a core AWS advantage over Azure Application
# Gateway Standard_v2, which does not support weighted routing between two pools.
#
# stickiness disabled: each request is independently routed, making the 10%
# distribution observable across a small number of requests.
resource "aws_lb_listener_rule" "items_canary" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 30

  action {
    type = "forward"

    forward {
      target_group {
        arn    = aws_lb_target_group.v1.arn
        weight = 90
      }

      target_group {
        arn    = aws_lb_target_group.v2.arn
        weight = 10
      }

      stickiness {
        enabled  = false
        duration = 1  # duration is required even when disabled; set to minimum
      }
    }
  }

  condition {
    path_pattern {
      values = ["/items", "/items/*"]
    }
  }

  tags = merge(var.tags, { Name = "${var.project_name}-rule-items-canary" })
}
```

> **Listener rule priorities:** Lower numbers are evaluated first. Rules 10 and 20 catch the explicit version paths before rule 30 sees them. The ALB default action (defined on the listener) is the last resort when no rule matches.

---

### `backends.tf`

```hcl
# ── IAM: ECS Task Execution Role ──────────────────────────────────────────────
# Assumed by the ECS agent (not the application code) to pull images from ECR Public
# and write logs to CloudWatch. The ECR pull permissions in this policy apply to
# ECR Private; ECR Public images are pulled anonymously, but the CloudWatch Logs
# permissions are always required.
resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project_name}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ── CloudWatch Log Groups ──────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "api_v1" {
  name              = "/ecs/${var.project_name}/api-v1"
  retention_in_days = 7

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "api_v2" {
  name              = "/ecs/${var.project_name}/api-v2"
  retention_in_days = 7

  tags = var.tags
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────
# A single cluster hosts both v1 and v2 services. ECS clusters are free;
# costs accrue only from the Fargate tasks running inside them.
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"  # set to "enabled" in production for enhanced metrics
  }

  tags = var.tags
}

# ── ECS Task Definition: API v1 ───────────────────────────────────────────────
# Fargate requires explicit CPU and memory at the task level.
# 256 CPU units = 0.25 vCPU; 512 MB is the minimum Fargate configuration.
resource "aws_ecs_task_definition" "api_v1" {
  family                   = "${var.project_name}-api-v1"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"  # required for Fargate; each task gets its own ENI
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name      = "api-v1"
    image     = var.api_image_v1
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.api_v1.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "api-v1"
      }
    }

    environment = []
  }])

  tags = var.tags
}

# ── ECS Task Definition: API v2 ───────────────────────────────────────────────
resource "aws_ecs_task_definition" "api_v2" {
  family                   = "${var.project_name}-api-v2"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name      = "api-v2"
    image     = var.api_image_v2
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.api_v2.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "api-v2"
      }
    }

    environment = []
  }])

  tags = var.tags
}

# ── ECS Service: API v1 ───────────────────────────────────────────────────────
# assign_public_ip = false: tasks run in private subnets with no direct internet access.
# ECS automatically registers and deregisters task IPs in the ALB target group
# via the load_balancer block — no manual target registration needed.
resource "aws_ecs_service" "api_v1" {
  name            = "${var.project_name}-svc-api-v1"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api_v1.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.private_a.id, aws_subnet.private_c.id]
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.v1.arn
    container_name   = "api-v1"
    container_port   = 8080
  }

  depends_on = [
    aws_lb_listener.https,
    aws_iam_role_policy_attachment.ecs_task_execution,
  ]

  tags = var.tags

  lifecycle {
    ignore_changes = [desired_count]
  }
}

# ── ECS Service: API v2 ───────────────────────────────────────────────────────
resource "aws_ecs_service" "api_v2" {
  name            = "${var.project_name}-svc-api-v2"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api_v2.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.private_a.id, aws_subnet.private_c.id]
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.v2.arn
    container_name   = "api-v2"
    container_port   = 8080
  }

  depends_on = [
    aws_lb_listener.https,
    aws_iam_role_policy_attachment.ecs_task_execution,
  ]

  tags = var.tags

  lifecycle {
    ignore_changes = [desired_count]
  }
}
```

> **Container image pull:** ECS Fargate tasks in private subnets need outbound internet access to pull images from ECR Public (`public.ecr.aws`). This is provided by the NAT Gateway in `network.tf`. Without NAT, task startup fails with `CannotPullContainerError`. Alternative: push images to ECR Private and add VPC Interface endpoints for ECR and S3 — this eliminates NAT Gateway cost but adds three extra VPC endpoints.

---

### `dns.tf`

```hcl
# ── Route53 Private Hosted Zone ───────────────────────────────────────────────
# A private hosted zone resolves only from within the associated VPC (and optionally
# from peered VPCs or VPN-connected networks). This is the AWS equivalent of
# Azure Private DNS Zone + VNet link.
#
# For public DNS (resolvable from the internet), use a public hosted zone
# with a real registered domain.
resource "aws_route53_zone" "main" {
  name    = var.dns_zone_name
  comment = "Private zone for ${var.project_name} exercise"

  vpc {
    vpc_id = aws_vpc.main.id
  }

  tags = var.tags
}

# ── Alias A Record: api → ALB DNS name ────────────────────────────────────────
# AWS ALB does not have a static public IP address (unlike Azure Application
# Gateway which supports a static IP). ALBs use a DNS name that resolves to
# multiple IPs managed by AWS — these IPs can change over time.
#
# The correct DNS pattern in AWS is a Route53 "alias record": a Route53-native
# extension to A records that points to the ALB DNS name and automatically
# follows IP changes. Alias records are free (no per-query charge).
#
# Consequence: unlike Azure where the A record holds a raw IP, here the record
# points to the ALB DNS name. curl commands must use the ALB DNS name directly
# when testing from outside the VPC.
resource "aws_route53_record" "api" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "api"  # creates api.module3.example.local
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
```

---

### `vpc_endpoint.tf` (Stretch Goal)

```hcl
# ── S3 VPC Gateway Endpoint ───────────────────────────────────────────────────
# Gateway endpoints are the recommended type for S3 (and DynamoDB).
# Unlike Interface endpoints, Gateway endpoints:
#   - Are FREE (no hourly charge, no data processing charge)
#   - Do not create an ENI in any subnet
#   - Work by injecting a route into specified route tables
# This is simpler and cheaper than Azure Private Endpoint for Storage Account.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.public.id,
    aws_route_table.private.id,
  ]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
      Resource  = [
        aws_s3_bucket.main.arn,
        "${aws_s3_bucket.main.arn}/*",
      ]
    }]
  })

  tags = merge(var.tags, { Name = "${var.project_name}-vpce-s3" })
}

# ── S3 Bucket ──────────────────────────────────────────────────────────────────
# S3 bucket names must be globally unique across all AWS accounts.
# Add the random provider to required_providers in main.tf:
#   random = { source = "hashicorp/random", version = "~> 3.0" }
resource "random_id" "s3_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "main" {
  bucket = "${var.project_name}-data-${random_id.s3_suffix.hex}"

  tags = merge(var.tags, { Name = "${var.project_name}-s3-data" })
}

resource "aws_s3_bucket_public_access_block" "main" {
  bucket = aws_s3_bucket.main.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Deny all access that does NOT come through the VPC endpoint.
resource "aws_s3_bucket_policy" "main" {
  bucket = aws_s3_bucket.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyNonVPCEndpointAccess"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [
        aws_s3_bucket.main.arn,
        "${aws_s3_bucket.main.arn}/*",
      ]
      Condition = {
        StringNotEquals = {
          "aws:sourceVpce" = aws_vpc_endpoint.s3.id
        }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.main]
}
```

---

### `outputs.tf`

```hcl
output "alb_dns_name" {
  description = "DNS name of the ALB. Use this in curl commands — ALB has no static IP."
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Route53 Hosted Zone ID of the ALB (used in alias records for external DNS)."
  value       = aws_lb.main.zone_id
}

output "api_hostname" {
  description = "Custom hostname (resolves only inside the VPC via Route53 private zone)."
  value       = "api.${var.dns_zone_name}"
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_v1_name" {
  description = "Name of the ECS service for API v1."
  value       = aws_ecs_service.api_v1.name
}

output "ecs_service_v2_name" {
  description = "Name of the ECS service for API v2."
  value       = aws_ecs_service.api_v2.name
}

output "acm_certificate_arn" {
  description = "ARN of the imported ACM certificate."
  value       = aws_acm_certificate.alb.arn
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}
```

---

## Deployment walkthrough

### Prerequisites

```powershell
# Verify required tools
aws --version          # AWS CLI >= 2.x
terraform --version    # Terraform >= 1.5.0

# Configure AWS credentials — choose one method:

# Method A: Environment variables
$env:AWS_ACCESS_KEY_ID     = "AKIA..."
$env:AWS_SECRET_ACCESS_KEY = "your-secret-key"
$env:AWS_DEFAULT_REGION    = "eu-west-1"

# Method B: Named profile (recommended for repeated use)
aws configure --profile module3
$env:AWS_PROFILE = "module3"

# Method C: AWS SSO (for IAM Identity Center organisations)
aws sso login --profile module3
$env:AWS_PROFILE = "module3"

# Verify credentials work — should print your UserId, Account, and ARN
aws sts get-caller-identity
```

### Container images

> **Required before deploying:** `api_image_v1` and `api_image_v2` must be publicly reachable from ECS Fargate in `eu-west-1`. Tasks run in private subnets and pull images outbound via NAT Gateway.

Images are pushed to **Amazon ECR Public** — the AWS-native public registry. Pulls from ECR Public require no authentication and work from any ECS task.

```powershell
# Create ECR Public repositories (one-time — ECR Public only exists in us-east-1)
aws ecr-public create-repository --repository-name lesson03-api-v1 --region us-east-1
aws ecr-public create-repository --repository-name lesson03-api-v2 --region us-east-1

# Get your registry alias (a short identifier AWS assigns to your account's public gallery)
$ECR_ALIAS = aws ecr-public describe-registries --region us-east-1 `
    --query "registries[0].aliases[0].name" --output text
Write-Host "ECR alias: $ECR_ALIAS"

# Log in to ECR Public (auth token is valid for 12 hours)
aws ecr-public get-login-password --region us-east-1 | `
    docker login --username AWS --password-stdin public.ecr.aws

# Build and push API v1
docker build -t "public.ecr.aws/$ECR_ALIAS/lesson03-api-v1:latest" homeworks/module3/src/api_v1
docker push "public.ecr.aws/$ECR_ALIAS/lesson03-api-v1:latest"

# Build and push API v2
docker build -t "public.ecr.aws/$ECR_ALIAS/lesson03-api-v2:latest" homeworks/module3/src/api_v2
docker push "public.ecr.aws/$ECR_ALIAS/lesson03-api-v2:latest"
```

Update `terraform.tfvars` with your alias before running `terraform apply`:

```powershell
# View current tfvars
Get-Content homeworks/module3/terraform_aws/terraform.tfvars

# Replace <your-ecr-alias> with the value of $ECR_ALIAS
(Get-Content homeworks/module3/terraform_aws/terraform.tfvars) `
    -replace '<your-ecr-alias>', $ECR_ALIAS | `
    Set-Content homeworks/module3/terraform_aws/terraform.tfvars
```

Verify the images are accessible before running `terraform apply`:

```powershell
# Log out first to test as an anonymous pull (no credentials)
docker logout public.ecr.aws
docker pull "public.ecr.aws/$ECR_ALIAS/lesson03-api-v1:latest"
docker pull "public.ecr.aws/$ECR_ALIAS/lesson03-api-v2:latest"
# Both should pull without authentication — confirming they are public
```

### Step 1 — Initialise and validate

```powershell
Set-Location "homeworks/module3/terraform_aws"

# Download provider plugins (aws ~> 5.0, tls ~> 4.0)
terraform init

# Check for syntax errors and missing references
terraform validate
# Expected: Success! The configuration is valid.

# Auto-format code (optional)
terraform fmt
```

### Step 2 — Plan

```powershell
# Preview all changes — no resources are created yet
terraform plan -out=tfplan

# The plan shows approximately 30 resources:
# + aws_vpc.main
# + aws_subnet.public_a, public_c, private_a, private_c
# + aws_internet_gateway.main
# + aws_eip.nat
# + aws_nat_gateway.main
# + aws_route_table.public, private (+ 4 associations)
# + aws_security_group.alb, ecs_tasks
# + tls_private_key.alb
# + tls_self_signed_cert.alb
# + aws_acm_certificate.alb
# + aws_lb.main
# + aws_lb_target_group.v1, v2
# + aws_lb_listener.https
# + aws_lb_listener_rule.v1_items, v2_items, items_canary
# + aws_iam_role.ecs_task_execution + policy attachment
# + aws_cloudwatch_log_group.api_v1, api_v2
# + aws_ecs_cluster.main
# + aws_ecs_task_definition.api_v1, api_v2
# + aws_ecs_service.api_v1, api_v2
# + aws_route53_zone.main
# + aws_route53_record.api
```

### Step 3 — Apply

```powershell
terraform apply tfplan
# Type "yes" when prompted to confirm.

# Estimated provisioning times:
#   NAT Gateway:     ~1-2 minutes
#   ALB:             ~2-3 minutes
#   ECS services:    ~2-3 minutes (task startup + health check)
#   Total:           ~5-8 minutes
```

### Step 4 — Retrieve the ALB DNS name

```powershell
# AWS ALB has no static IP — always use the DNS name
$ALB_DNS = terraform output -raw alb_dns_name
Write-Host "ALB DNS: $ALB_DNS"
# Example: module3-networking-alb-1234567890.eu-west-1.elb.amazonaws.com
```

### Step 5 — Test path-based routing

```powershell
# -k skips TLS certificate verification (expected for self-signed cert)
# Wait 30-60 seconds after apply for ECS health checks to pass before testing

# v1: should return a JSON array
curl.exe -k "https://$ALB_DNS/v1/items"
# Expected: [{"id":1,"name":"Widget"}, ...]

# v2: should return a JSON object with _version:"v2" and a data array
curl.exe -k "https://$ALB_DNS/v2/items"
# Expected: {"_version":"v2","data":[...],"total":...}
```

### Step 6 — Test the 90/10 canary split

```powershell
$v2Count = 0
for ($i = 1; $i -le 50; $i++) {
    $response = curl.exe -sk "https://$ALB_DNS/items"
    if ($response -match '"_version"') { $v2Count++ }
}

$pct = [math]::Round(($v2Count / 50) * 100, 1)
Write-Host "v2 responses: $v2Count / 50 ($pct%)"

if ($v2Count -ge 2 -and $v2Count -le 10) {
    Write-Host "PASS: canary split within expected range" -ForegroundColor Green
} else {
    Write-Host "WARN: outside expected range — re-run (binomial variance is normal)" -ForegroundColor Yellow
}
```

### Step 7 — Verify TLS offloading

```powershell
# Confirm backend target groups use HTTP (not HTTPS) — this is TLS offloading
aws elbv2 describe-target-groups `
    --names "${env:TF_VAR_project_name}-tg-v1" "${env:TF_VAR_project_name}-tg-v2" `
    --query "TargetGroups[].{Name:TargetGroupName,Protocol:Protocol,Port:Port}" `
    --output table
# Expected: Protocol=HTTP, Port=8080 for both groups

# Confirm listener uses HTTPS with the modern TLS policy
$albArn = aws elbv2 describe-load-balancers `
    --names "module3-networking-alb" `
    --query "LoadBalancers[0].LoadBalancerArn" `
    --output text
aws elbv2 describe-listeners `
    --load-balancer-arn $albArn `
    --query "Listeners[].{Port:Port,Protocol:Protocol,SslPolicy:SslPolicy}" `
    --output table
# Expected: Port=443, Protocol=HTTPS, SslPolicy=ELBSecurityPolicy-TLS13-1-2-2021-06
```

### Step 8 — Verify backends have no public IP

```powershell
$clusterName = terraform output -raw ecs_cluster_name

# List running task ARNs for v1 service
$taskArns = aws ecs list-tasks `
    --cluster $clusterName `
    --service-name "module3-networking-svc-api-v1" `
    --query "taskArns" `
    --output text

# Check for public IP — expected: empty (no public IP assigned)
aws ecs describe-tasks `
    --cluster $clusterName `
    --tasks $taskArns `
    --query "tasks[0].attachments[0].details[?name=='publicIPv4Address']" `
    --output json
# Expected: []

# Confirm private IP is in the private subnet range (10.10.2.x or 10.10.4.x)
aws ecs describe-tasks `
    --cluster $clusterName `
    --tasks $taskArns `
    --query "tasks[0].attachments[0].details[?name=='privateIPv4Address'].value" `
    --output text
# Expected: 10.10.2.x or 10.10.4.x
```

### Step 9 — Test DNS hostname

```powershell
# Route53 private hosted zone resolves only inside the VPC.
# From outside the VPC, use curl's --resolve flag to override DNS:
$albIp = (Resolve-DnsName $ALB_DNS -Type A | Select-Object -First 1).IPAddress
curl.exe -k --resolve "api.module3.example.local:443:$albIp" `
    "https://api.module3.example.local/v1/items"
# Expected: same response as hitting the ALB DNS name directly
```

### Step 10 — Stretch: Verify S3 VPC endpoint

```powershell
# Check endpoint state
aws ec2 describe-vpc-endpoints `
    --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)" `
    --query "VpcEndpoints[?contains(ServiceName,'s3')].{State:State,Type:VpcEndpointType}" `
    --output table
# Expected: State=available, Type=Gateway

# From outside the VPC — bucket policy denies access (no VPC endpoint in path)
$bucketName = aws s3api list-buckets `
    --query "Buckets[?contains(Name,'module3-networking-data')].Name" `
    --output text
aws s3 ls "s3://$bucketName/"
# Expected: An error occurred (AccessDenied)

# From inside the VPC (ECS Exec, requires enable_execute_command = true on service):
# aws s3 ls s3://$bucketName/ --region eu-west-1
# Expected: (empty or object list — access succeeds via VPC endpoint)
```

### Step 11 — Destroy

```powershell
terraform destroy
# Review the plan and type "yes" to confirm.
# Estimated destroy time: ~5-10 minutes
# NAT Gateway deletion takes ~1 minute on its own.

# Verify VPC is removed
aws ec2 describe-vpcs `
    --filters "Name=tag:project,Values=module3-networking" `
    --query "Vpcs" `
    --output json
# Expected: []
```

---

## Verification checklist

After `terraform apply`, validate each acceptance criterion from `module3_networking.md`:

| Criterion | How to check |
|---|---|
| `terraform validate` and `terraform plan` produce no errors | Step 1 and 2 above |
| Path `/v1/items*` returns v1 response | `curl.exe -k "https://$ALB_DNS/v1/items"` |
| Path `/v2/items*` returns v2 response | `curl.exe -k "https://$ALB_DNS/v2/items"` |
| Canary split: 2-10 v2 responses out of 50 | 50-request loop in Step 6 |
| Backend instances have no public IPs | `aws ecs describe-tasks` in Step 8 |
| TLS offloaded at ALB (backend uses HTTP 8080) | `aws elbv2 describe-target-groups` in Step 7 |
| DNS resolves to load balancer | `--resolve` curl test in Step 9 |
| `terraform destroy` removes all resources | Verify VPC gone in Step 11 |
| (Stretch) S3 accessible from VPC, denied from outside | Access-denied test in Step 10 |

---

## Security and architecture notes

### Security Group design vs Azure NSG

Azure NSGs are subnet-level rules evaluated on the subnet boundary. AWS Security Groups are attached to network interfaces (ENIs) and evaluated per resource:

- `sg-alb`: inbound 443 from `0.0.0.0/0`; all outbound. Attached to the ALB.
- `sg-ecs-tasks`: inbound 8080 from `sg-alb` **by SG ID reference**. Attached to each ECS task's ENI.

The SG reference (`security_groups = [aws_security_group.alb.id]`) is more precise than a CIDR rule: if the ALB subnets change IPs, the rule remains valid. AWS SGs have an implicit default-deny — no explicit deny rules are needed (unlike Azure NSGs where explicit denies can be useful for documentation clarity).

### TLS offloading

TLS terminates at the ALB using the ACM-imported self-signed certificate. ECS tasks receive plain HTTP on port 8080. The `protocol = "HTTP"` on `aws_lb_target_group` is the single control point. For end-to-end TLS in production, set `protocol = "HTTPS"` on the target group and install a certificate on the container.

### Self-signed certificate: PEM vs PFX

Azure Application Gateway requires a PFX (PKCS#12) binary with an embedded private key and password. AWS ACM `import` accepts PEM directly via `certificate_body` and `private_key` attributes — no `openssl pkcs12` conversion step is needed. The TLS provider outputs PEM natively, so the pipeline is: `tls_private_key` → `tls_self_signed_cert` → `aws_acm_certificate` with no intermediate steps.

### ECS Fargate vs Azure Container Instances

| Aspect | ECS Fargate | Azure Container Instances |
|---|---|---|
| VPC/VNet placement | `awsvpc` mode — each task gets its own ENI | `subnet_ids` — each container group gets a private IP |
| Subnet constraint | Any subnet; no delegation required | Subnet must be delegated to `Microsoft.ContainerInstance/containerGroups` |
| Private Endpoint compatibility | Private subnets work alongside VPC endpoints in any subnet | Delegated subnet cannot host private endpoints — needs a separate subnet |
| Health checks | ALB target group health checks | Application Gateway backend health probes |
| Image pull | Via NAT Gateway or ECR VPC Interface endpoints | Direct internet access (no NAT GW needed) |
| IAM / RBAC | ECS task execution role (IAM) | Managed Identity (optional) |

### AWS Well-Architected alignment

| Pillar | Applied practice |
|---|---|
| Security | Private subnets for backends; SG reference (not CIDR) for ALB→backend; TLS at ALB; ACM-managed cert; no public IPs on tasks |
| Reliability | ALB spans 2 AZs; ECS service with health check dependency; `desired_count = 1` (increase to 2+ for HA) |
| Cost Optimization | Single NAT GW (acceptable for exercise); Fargate pay-per-task; short CloudWatch log retention; always `terraform destroy` after exercise |
| Operational Excellence | All infra in Terraform; CloudWatch log groups; `terraform destroy` + re-`apply` verified by acceptance criteria |
| Performance Efficiency | Fargate cold start ~30-60 s; ALB scales automatically; weighted routing without external service |

---

## Known limitations

### 1. ALB has no static IP (key difference from Azure)

AWS ALB uses a DNS name (`xxx.eu-west-1.elb.amazonaws.com`) that resolves to multiple IPs managed dynamically by AWS. You cannot pin an IP to an A record. Consequences:
- Route53 alias records must be used instead of raw A records with IPs.
- `curl` commands from outside the VPC must target the ALB DNS name.
- The homework criterion "DNS A record → LB public IP" is satisfied by the Route53 alias record (which Route53 internally resolves to the current ALB IPs).

### 2. Private hosted zone resolution scope

`nslookup api.module3.example.local` from your local machine will not resolve — the zone is visible only inside the VPC. Workarounds for outside-VPC testing:
- Use the ALB DNS name directly in `curl` commands.
- Use `curl.exe --resolve "hostname:443:IP"` to force hostname mapping.
- Use ECS Exec or a bastion EC2 instance for in-VPC DNS queries.

### 3. NAT Gateway cost

NAT Gateway costs ~$0.045/hour (~$32/month) plus $0.045/GB data transfer in `eu-west-1`. For a short exercise session the total is a few cents. **Always run `terraform destroy` when done.**

Alternatives that eliminate NAT Gateway cost (added complexity):
- Push images to ECR Private + add VPC Interface endpoints for ECR API, ECR DKR, and S3 (3 endpoints × $0.01/hour each).
- Assign `assign_public_ip = true` on ECS tasks and place them in public subnets — this violates the "no public IPs on backends" requirement.

### 4. ECS task health check delay

ALB returns HTTP 503 for ~30-60 seconds after `terraform apply` while:
1. ECS schedules the Fargate task and pulls the container image.
2. The container starts and binds port 8080.
3. The ALB health check reaches `healthy_threshold = 2` consecutive successes.

If `curl` returns 503 immediately after apply, wait and retry. Check service events:

```powershell
aws ecs describe-services `
    --cluster (terraform output -raw ecs_cluster_name) `
    --services "module3-networking-svc-api-v1" `
    --query "services[0].events[0:5]" `
    --output json
```

### 5. Canary split statistical variance

With 50 requests and 10% weight on v2, the expected count follows a binomial distribution (mean ≈ 5, standard deviation ≈ 2.1). The acceptance range (2-10) covers ±1.5 standard deviations — approximately 87% of runs. If a run lands outside the range by chance, re-run the 50-request loop.

### 6. Container image availability

Images are hosted on Amazon ECR Public (`public.ecr.aws/<alias>/...`) and must be pushed before `terraform apply`. If the images are missing or the repository name is wrong, the ECS task fails with `CannotPullContainerError` visible in ECS service events. Verify the ECR alias in `terraform.tfvars` matches the value returned by `aws ecr-public describe-registries`. If using ECR Private instead, add `repositoryCredentials` to the task definition referencing a Secrets Manager ARN for the pull credentials.

### 7. Terraform state security

`tls_private_key.alb` stores the RSA private key in Terraform state in plaintext (marked `sensitive = true` in outputs, but readable in the state file). For production:
- Use a remote backend (S3 bucket + DynamoDB table for state locking) with SSE-KMS encryption.
- Add `terraform.tfstate*` and `terraform.tfvars` to `.gitignore`.
- Never commit state files to source control.

### 8. Stretch goal: `random` provider dependency

`vpc_endpoint.tf` uses `random_id` for a unique S3 bucket name. Before running `terraform init` with the stretch goal files, add the `random` provider to `main.tf`:

```hcl
random = {
  source  = "hashicorp/random"
  version = "~> 3.0"
}
```
