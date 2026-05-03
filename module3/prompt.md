## Azure implementation

Use `module3_networking_azure.md` to generate Terraform files into `terraform_az/`. Make sure all conditions from `module3_networking.md` are covered and we're following the solution definition. Prepare Terraform files and validate with `terraform init` and `terraform plan`.

Once done, give me the full list of commands I should execute to:

* validate and build this
* apply into production

Explain them like I'm a junior developer. Put both sets of commands into a README file as well for future reference.

Before running any Terraform commands, authenticate with Azure:

```powershell
az login
az account set --subscription "<your-subscription-id>"
az account show   # confirm the correct subscription is selected
```

Use PowerShell for all shell commands (Windows environment — no bash syntax, no `export`, no `$(...)` subshells).

---

## AWS implementation

Use `module3_networking_aws.md` to generate Terraform files into `terraform_aws/`. Make sure all conditions from `module3_networking.md` are covered and the solution follows the AWS guide. Prepare Terraform files and validate with `terraform init` and `terraform plan`.

Once done, give me the full list of commands I should execute to:

* validate and build this
* apply into production

Explain them like I'm a junior developer. Put both sets of commands into a README file as well for future reference.

Before running any Terraform commands, authenticate with AWS:

```powershell
# Option A: environment variables (simplest)
$env:AWS_ACCESS_KEY_ID     = "AKIA..."
$env:AWS_SECRET_ACCESS_KEY = "your-secret-key"
$env:AWS_DEFAULT_REGION    = "eu-west-1"

# Option B: named profile
aws configure --profile module3
$env:AWS_PROFILE = "module3"

# Verify credentials
aws sts get-caller-identity
```

Key differences vs Azure to keep in mind:
- There is no Resource Group equivalent — resources are organised by VPC and tags.
- ALB has no static IP; use the ALB DNS name from `terraform output alb_dns_name` in all curl tests.
- `curl` on Windows is `curl.exe` — use that form to avoid the PowerShell alias.
- The Route53 private hosted zone resolves only inside the VPC; test DNS with `--resolve` flag outside the VPC.
- Always run `terraform destroy` after the exercise — NAT Gateway charges ~$0.045/hour.

Use PowerShell for all shell commands (Windows environment — no bash syntax, no `export`, no `$(...)` subshells).
