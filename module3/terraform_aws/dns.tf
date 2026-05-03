# ── Route53 Private Hosted Zone ───────────────────────────────────────────────
# Resolves only from inside the associated VPC.
# From outside the VPC use the ALB DNS name directly or curl --resolve.
resource "aws_route53_zone" "main" {
  name    = var.dns_zone_name
  comment = "Private zone for ${var.project_name} exercise"

  vpc {
    vpc_id = aws_vpc.main.id
  }

  tags = var.tags
}

# ── Alias A Record: api → ALB DNS name ────────────────────────────────────────
# ALB has no static IP — Route53 alias record is the correct pattern.
# Alias records are free and automatically follow IP changes in the ALB.
resource "aws_route53_record" "api" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "api"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
