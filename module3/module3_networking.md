# Homework — Module 3: Networking

## Learning objectives

- Configure path-based routing on an L7 load balancer to direct traffic to multiple API versions
- Implement weighted traffic splitting (canary release) at the load balancer level without changing client code
- Distinguish between L4 and L7 load balancing and select the correct layer for a given use case
- Configure TLS offloading at the load balancer so backend services communicate over plain HTTP internally
- Design a VNet/VPC with public and private subnets and enforce that backend compute is not directly reachable from the internet
- Attach a Private Endpoint to a PaaS storage or database service and verify that the service is unreachable over its public endpoint
- Express all infrastructure as Terraform code that can be destroyed and re-created repeatably

## Application concept

The homework deploys two versions of a minimal REST API behind a single L7 load balancer hostname. Version 1 (`/v1/items`) returns a flat JSON array of items. Version 2 (`/v2/items`) returns a JSON object that wraps the same list with pagination metadata (`total`, `page`, `page_size`) and a `_version: "v2"` field. Both versions are deployed as separate container instances or compute units so that the load balancer can route to each independently.

The root path `/items` is configured with a 90 % / 10 % weighted split between v1 and v2, simulating a canary release where a small fraction of real traffic is sent to the new version before a full rollout. Students observe how the load balancer distributes requests by calling `/items` repeatedly and recording which response shape they receive. An optional stretch goal places both backend services inside a private subnet with no public IP, making them reachable only through the load balancer and, within the VNet, through a Private Endpoint attached to a backing storage or database service.

## Architecture overview

- L7 load balancer / application gateway with a single public IP and TLS certificate (self-signed acceptable for the exercise)
- Two backend pools: `pool-v1` targeting the v1 API, `pool-v2` targeting the v2 API
- Path-based routing rules: `/v1/items*` → `pool-v1`, `/v2/items*` → `pool-v2`
- Weighted routing rule on `/items*`: 90 % weight to `pool-v1`, 10 % weight to `pool-v2`
- TLS listener on port 443; backends receive plain HTTP on port 8080
- VNet/VPC with at least two subnets: one public (load balancer), one private (backend compute)
- Network Security Group / Security Group on the private subnet: allow inbound 8080 only from the load balancer subnet, deny all other inbound internet traffic
- Optional: Private Endpoint for an Azure Storage Account or AWS S3 VPC Endpoint (gateway type) in the private subnet
- DNS A record pointing `api.example.local` (or any test domain) to the load balancer public IP

## Cloud resources to provision (via Terraform)

| Resource | Azure equivalent | AWS equivalent |
|---|---|---|
| Virtual network | `azurerm_virtual_network` | `aws_vpc` |
| Public subnet | `azurerm_subnet` (delegated to Application Gateway) | `aws_subnet` with `map_public_ip_on_launch = true` |
| Private subnet | `azurerm_subnet` | `aws_subnet` with `map_public_ip_on_launch = false` |
| Network Security Group | `azurerm_network_security_group` + `azurerm_subnet_network_security_group_association` | `aws_security_group` attached to instances |
| L7 load balancer | `azurerm_application_gateway` | `aws_lb` (type = `application`) |
| Load balancer listener (HTTPS 443) | `azurerm_application_gateway` frontend config | `aws_lb_listener` (protocol = `HTTPS`) |
| TLS certificate | `azurerm_key_vault_certificate` or inline PFX in `azurerm_application_gateway` | `aws_acm_certificate` (imported self-signed) |
| Backend pool — v1 | `backend_address_pool` block inside `azurerm_application_gateway` | `aws_lb_target_group` (`pool-v1`) |
| Backend pool — v2 | `backend_address_pool` block inside `azurerm_application_gateway` | `aws_lb_target_group` (`pool-v2`) |
| Path-based routing rule | `url_path_map` + `path_rule` blocks | `aws_lb_listener_rule` with `path-pattern` condition |
| Weighted routing rule (canary) | `request_routing_rule` with multiple `backend_address_pool` targets via `rewrite_rule_set` or Traffic Manager weighted profiles | `aws_lb_listener_rule` with `weighted` forward action |
| Backend compute (v1) | `azurerm_container_group` or `azurerm_linux_virtual_machine` | `aws_instance` or ECS Fargate task |
| Backend compute (v2) | `azurerm_container_group` or `azurerm_linux_virtual_machine` | `aws_instance` or ECS Fargate task |
| Public IP for load balancer | `azurerm_public_ip` | Allocated automatically by `aws_lb` |
| DNS record | `azurerm_dns_a_record` (Azure DNS zone) | `aws_route53_record` |
| Private Endpoint (stretch) | `azurerm_private_endpoint` + `azurerm_private_dns_zone` | `aws_vpc_endpoint` (Interface type) or Gateway type for S3 |
| Storage / database backend (stretch) | `azurerm_storage_account` | `aws_s3_bucket` |

## Exercise tasks

1. **Set up the directory structure.** In your local checkout of the course repository (on your working branch), navigate to `homeworks/module3/`. Create a `terraform/` directory inside it containing `main.tf`, `variables.tf`, `outputs.tf`, and `terraform.tfvars`. Run `terraform init` and confirm no errors before writing any resources.

2. **Provision the network.** Define a VNet (address space `10.10.0.0/16`) with two subnets: `subnet-lb` (`10.10.1.0/24`) and `subnet-backend` (`10.10.2.0/24`). Attach a Network Security Group to `subnet-backend` that allows inbound TCP 8080 only from `10.10.1.0/24` and denies all other inbound traffic from the internet.

3. **Deploy the two API backends.** Use Azure Container Instances (or AWS ECS Fargate tasks) to run the `lesson03-api-v1` and `lesson03-api-v2` container images built from `homeworks/module3/src/api_v1` and `homeworks/module3/src/api_v2`. Push images to the platform-specific registry first (ACR for Azure, ECR Public for AWS). Place both containers in `subnet-backend` with no public IP assigned. Confirm from the Azure portal or AWS console that neither instance has a public IP.

4. **Create the L7 load balancer.** Define an Application Gateway (SKU `Standard_v2`) in `subnet-lb` with a public IP. Configure a self-signed TLS certificate and a single HTTPS listener on port 443. Output the public IP address from Terraform.

5. **Configure path-based routing.** Add two path rules to the Application Gateway URL path map: `/v1/items*` → `pool-v1`, `/v2/items*` → `pool-v2`. Verify by running the following commands after `terraform apply` and confirming the expected response shapes:
   ```
   curl -k https://<LB_IP>/v1/items
   curl -k https://<LB_IP>/v2/items
   ```
   `/v1/items` must return a JSON array. `/v2/items` must return a JSON object containing `_version: "v2"` and a `data` array.

6. **Configure the 90/10 weighted canary split on `/items`.** Add a routing rule that sends 90 % of requests matching `/items` to `pool-v1` and 10 % to `pool-v2`. Run the following shell loop and record how many responses contain `_version`:
   ```bash
   for i in $(seq 1 50); do curl -sk https://<LB_IP>/items; echo; done | grep -c '"_version"'
   ```
   The count must be between 2 and 10 out of 50 requests (accepting statistical variance around the 10 % target).

7. **Verify TLS offloading.** Confirm that backend services are configured to listen on plain HTTP (port 8080) and that the Application Gateway backend HTTP settings use `http` protocol on port 8080. Capture a screenshot or `terraform show` excerpt showing the backend protocol setting.

8. **Add a DNS record.** Using Azure DNS (or Route 53), create an A record `api.module3.example.local` pointing to the load balancer public IP. Update your curl commands to use the hostname and verify the routing rules still work.

9. **(Stretch) Enable Private Endpoint for a backing service.** Provision an Azure Storage Account (or AWS S3 bucket) and attach a Private Endpoint in `subnet-backend`. Disable public network access on the Storage Account. From within one of the backend container instances, confirm that the storage hostname resolves to a `10.10.2.x` address and that a `curl` or `az storage blob list` call succeeds. Confirm that the same call from outside the VNet returns an authorization or network error (not a successful response).

10. **Destroy and re-create.** Run `terraform destroy` followed immediately by `terraform apply`. The full cycle must complete without manual intervention and produce the same routing behavior as verified in tasks 5 and 6.

## Acceptance criteria

- `terraform validate` and `terraform plan` produce no errors and no unexpected resource replacements on a second run (plan is idempotent after apply)
- `curl -k https://<LB_IP>/v1/items` returns HTTP 200 with a JSON array body
- `curl -k https://<LB_IP>/v2/items` returns HTTP 200 with a JSON object body that includes both `"_version": "v2"` and a `"data"` key
- Running the 50-request loop against `/items` yields between 2 and 10 responses containing `"_version"` (confirming ~10 % canary split; exact range accounts for binomial variance)
- Neither backend instance has a public IP address; a direct `curl http://<backend-private-ip>:8080/v1/items` from a machine outside the VNet times out or is refused
- The Application Gateway backend HTTP settings show protocol `HTTP` and port `8080`, confirming TLS is terminated at the gateway and not end-to-end
- The DNS A record resolves to the load balancer public IP (`nslookup api.module3.example.local` or `dig +short api.module3.example.local` returns the load balancer IP)
- (Stretch) `nslookup <storage-account>.blob.core.windows.net` from inside the VNet resolves to a `10.10.2.x` private IP; the same lookup from outside the VNet resolves to a public Microsoft IP
- (Stretch) A `curl` to the storage account public endpoint from outside the VNet returns HTTP 403 or a network error, not HTTP 200
- `terraform destroy` removes all provisioned resources without errors; the Azure resource group (or AWS VPC) is empty afterward
