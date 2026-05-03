# Module 3 — AWS Networking (Terraform)

Deploys the versioned Items API behind an AWS Application Load Balancer with path-based routing, 90/10 weighted canary split, TLS offloading, and private ECS Fargate backends. See `module3_networking_aws.md` for the full implementation guide.

## Prerequisites

1. **AWS CLI** — `aws --version` (>= 2.x)
2. **Terraform** — `terraform --version` (>= 1.5.0)
3. **Docker Desktop** — `docker --version` — needed to build and push the API images

## Build and push container images to ECR Public (one-time, before first deploy)

ECR Public is the AWS-native public container registry — free, no authentication required for pulls.

> **Region note:** ECR Public repositories must be created via `--region us-east-1` — this is an AWS service constraint (ECR Public's control plane is global and hosted in us-east-1 only). Your actual workloads (ECS, ALB, VPC) all run in `eu-west-1`.

```powershell
# Create ECR Public repositories (one-time — ECR Public control plane is in us-east-1 by AWS design)
aws ecr-public create-repository --repository-name lesson03-api-v1 --region us-east-1
aws ecr-public create-repository --repository-name lesson03-api-v2 --region us-east-1

# Get your registry alias (a short identifier AWS assigns to your public gallery)
$ECR_ALIAS = aws ecr-public describe-registries --region us-east-1 `
    --query "registries[0].aliases[0].name" --output text
Write-Host "Your ECR alias: $ECR_ALIAS"

# Log in to ECR Public
aws ecr-public get-login-password --region us-east-1 | `
    docker login --username AWS --password-stdin public.ecr.aws

# Build and push API v1
docker build -t "public.ecr.aws/$ECR_ALIAS/lesson03-api-v1:latest" homeworks/module3/src/api_v1
docker push "public.ecr.aws/$ECR_ALIAS/lesson03-api-v1:latest"

# Build and push API v2
docker build -t "public.ecr.aws/$ECR_ALIAS/lesson03-api-v2:latest" homeworks/module3/src/api_v2
docker push "public.ecr.aws/$ECR_ALIAS/lesson03-api-v2:latest"

# Update terraform.tfvars with your alias
# api_image_v1 = "public.ecr.aws/<your-alias>/lesson03-api-v1:latest"
# api_image_v2 = "public.ecr.aws/<your-alias>/lesson03-api-v2:latest"
```

## Generate and import TLS certificate (one-time, before first deploy)

AWS ACM cannot generate self-signed certificates — it only issues validated certs
(requires a real domain) or accepts imported certs. The Terraform `tls` provider
always sets `not_before = now()`, which AWS rejects due to clock skew. The
work-around is to generate the cert outside Terraform with a backdated start time
using PowerShell + the `openssl` binary bundled with Git for Windows.

```powershell
# 1. Generate self-signed cert backdated 1 hour (avoids ACM clock-skew rejection)
$cert = New-SelfSignedCertificate `
    -DnsName "api.module3.example.local" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -NotBefore (Get-Date).AddHours(-1) `
    -NotAfter (Get-Date).AddDays(365) `
    -KeyAlgorithm RSA -KeyLength 2048

# 2. Export cert + private key as PFX
$pfxPwd = "TempPwd123!"
$pfxPath = "$env:TEMP\module3-cert.pfx"
Export-PfxCertificate -Cert $cert -FilePath $pfxPath `
    -Password (ConvertTo-SecureString $pfxPwd -Force -AsPlainText)

# 3. Split into cert.pem and key.pem using openssl from Git for Windows
$openssl = "C:\Program Files\Git\usr\bin\openssl.exe"
& $openssl pkcs12 -in $pfxPath -nokeys -out cert.pem -passin "pass:$pfxPwd" 2>$null
& $openssl pkcs12 -in $pfxPath -nocerts -nodes -out key.pem -passin "pass:$pfxPwd" 2>$null

# 4. Import to ACM and capture the ARN
$CERT_ARN = aws acm import-certificate `
    --certificate fileb://cert.pem `
    --private-key fileb://key.pem `
    --region eu-west-1 `
    --query CertificateArn --output text
Write-Host "Certificate ARN: $CERT_ARN"

# 5. Write ARN into terraform.tfvars
(Get-Content terraform.tfvars) -replace `
    'acm_certificate_arn = ".*"', `
    "acm_certificate_arn = `"$CERT_ARN`"" | Set-Content terraform.tfvars

# 6. Clean up local files
Remove-Item $pfxPath, cert.pem, key.pem
```

> **Re-deploy note:** ACM certificates are not managed by Terraform state. If you
> run `terraform destroy`, the certificate stays in ACM and the same ARN remains
> valid for the next `terraform apply`. Only re-run this section if you explicitly
> delete the certificate from ACM.

## Authenticate with AWS (PowerShell)

```powershell
# Option A: environment variables
$env:AWS_ACCESS_KEY_ID     = "AKIA..."
$env:AWS_SECRET_ACCESS_KEY = "your-secret-key"
$env:AWS_DEFAULT_REGION    = "eu-west-1"

# Option B: named profile
aws configure --profile module3
$env:AWS_PROFILE = "module3"

# Verify
aws sts get-caller-identity
```

## Validate and build (before first deploy)

```powershell
Set-Location "homeworks/module3/terraform_aws"

# Download providers (aws ~> 5.0, tls ~> 4.0)
terraform init

# Check for errors
terraform validate

# Preview all changes — nothing is created yet (~30 resources)
terraform plan -out=tfplan
```

## Apply to production

```powershell
# Create all resources (~5-8 minutes)
terraform apply tfplan

# Get the ALB DNS name — use this in all curl commands
$ALB_DNS = terraform output -raw alb_dns_name
Write-Host "ALB: https://$ALB_DNS"

# Wait ~60 seconds for ECS health checks to pass, then test:
curl.exe -k "https://$ALB_DNS/v1/items"   # flat array
curl.exe -k "https://$ALB_DNS/v2/items"   # paginated object with _version:"v2"
curl.exe -k "https://$ALB_DNS/items"      # canary: ~90% v1, ~10% v2

# Canary split verification (50 requests, expect 2-10 v2 responses)
$v2Count = 0
for ($i = 1; $i -le 50; $i++) {
    if ((curl.exe -sk "https://$ALB_DNS/items") -match '"_version"') { $v2Count++ }
}
Write-Host "v2 responses: $v2Count / 50"
```

## Destroy

```powershell
# Always destroy after the exercise — NAT Gateway costs ~$0.045/hour
terraform destroy
```

## Stretch goal — S3 VPC Gateway Endpoint

See `vpc_endpoint.tf` template in `module3_networking_aws.md`. Before using it:
1. Uncomment the `random` provider block in `main.tf`
2. Create `vpc_endpoint.tf` with the content from the guide
3. Re-run `terraform init` then `terraform apply`

## File structure

| File | Purpose |
|---|---|
| `main.tf` | Provider config |
| `network.tf` | VPC, subnets, IGW, NAT GW, route tables, security groups |
| `alb.tf` | ALB, ACM cert, target groups, HTTPS listener, listener rules |
| `backends.tf` | IAM role, CloudWatch logs, ECS cluster, task defs, services |
| `dns.tf` | Route53 private zone + alias A record |
| `variables.tf` | Input variable declarations |
| `outputs.tf` | ALB DNS name, cluster name, VPC ID |
| `terraform.tfvars` | Concrete values (gitignored) |
