variable "aws_region" {
  type        = string
  default     = "eu-west-1"
  description = "AWS region for all infrastructure. eu-west-1 (Ireland) is the default EU West region. eu-west-2 (London) and eu-west-3 (Paris) are acceptable alternatives. Note: ECR Public repositories are always managed via us-east-1 regardless of this setting — that is an AWS service constraint, not an infrastructure choice."
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

variable "acm_certificate_arn" {
  type        = string
  description = "ARN of the ACM certificate to attach to the HTTPS listener. Generate and import it before running terraform apply — see README.md 'Generate and import TLS certificate'."
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
