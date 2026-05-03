terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Uncomment if using the stretch goal (vpc_endpoint.tf):
    # random = {
    #   source  = "hashicorp/random"
    #   version = "~> 3.0"
    # }
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
}
