aws_region    = "eu-west-1"
project_name  = "module3-networking"

# Build and push to ECR Public before running terraform apply.
# Get your alias: aws ecr-public describe-registries --region us-east-1 --query "registries[0].aliases[0].name" --output text
# Then replace <your-ecr-alias> below with the value returned.
api_image_v1 = "public.ecr.aws/<CHANGE_ME>/lesson03-api-v1:latest"
api_image_v2 = "public.ecr.aws/<CHANGE_ME>/lesson03-api-v2:latest"

dns_zone_name = "module3.example.local"

# ACM certificate ARN — generate and import BEFORE running terraform apply.
# See README.md "Generate and import TLS certificate" for the PowerShell commands.
acm_certificate_arn = "arn:aws:acm:eu-west-1:<CHANGE_ME>:certificate/<CHANGE_ME>"
