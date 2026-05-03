output "alb_dns_name" {
  description = "DNS name of the ALB. Use this in curl commands — ALB has no static IP."
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Route53 Hosted Zone ID of the ALB (for alias records in external DNS)."
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
  description = "ARN of the ACM certificate attached to the HTTPS listener."
  value       = var.acm_certificate_arn
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}
