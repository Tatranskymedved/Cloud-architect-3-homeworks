# ── TLS note ──────────────────────────────────────────────────────────────────
# ACM cannot generate self-signed certs on its own. It either issues validated
# certs (requires a real public domain) or accepts imported certs.
# The Terraform tls provider always sets not_before = now(), which causes AWS
# to reject the import with "certificate is valid in the future" due to clock
# skew. Work-around: generate the cert outside Terraform using PowerShell +
# openssl (Git for Windows ships openssl), then import to ACM manually before
# running terraform apply. See README.md "Generate and import TLS certificate".
# The ARN is passed in via var.acm_certificate_arn.

# ── Application Load Balancer ──────────────────────────────────────────────────
resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_c.id]

  tags = merge(var.tags, { Name = "${var.project_name}-alb" })
}

# ── Target Group: v1 ──────────────────────────────────────────────────────────
# target_type = "ip" is required for ECS Fargate (awsvpc network mode).
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
# TLS is terminated here — backends receive plain HTTP on port 8080 (TLS offload).
# ELBSecurityPolicy-TLS13-1-2-2021-06 supports TLS 1.2 and 1.3 (recommended 2026).
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.v1.arn
  }

  tags = merge(var.tags, { Name = "${var.project_name}-listener-https" })
}

# ── Listener Rule: /v1/items* → Target Group v1 ───────────────────────────────
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
# Native AWS ALB weighted routing — no workaround needed unlike Azure App Gateway.
# Rules 10 and 20 catch explicit version paths first; this rule only sees /items*.
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
        duration = 1
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
