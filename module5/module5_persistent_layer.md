# Homework — Module 5: Persistent Layer

## Learning objectives

- Understand when to use relational databases, object storage, cache, and NoSQL, and how to combine them in a single application
- Implement the cache-aside pattern with a fixed TTL and reason about cache invalidation trade-offs
- Route read traffic to a PostgreSQL read replica and observe replication lag under write load
- Simulate a primary-node failover and verify that the application recovers automatically
- Store and retrieve binary objects (images, PDFs) via pre-signed URLs without exposing storage credentials
- Provision all infrastructure with Terraform and restrict data-plane access using Private Endpoints / VPC-internal networking

## Application concept

The Product Catalog API is a read-heavy REST service that manages a catalog of products, each with structured metadata (name, description, price, stock level), a cover image, and a PDF datasheet. Because product reads outnumber writes by a large margin, the API routes every GET request through a three-tier storage stack: it first checks a Redis cache, falls back to a PostgreSQL read replica for a cache miss, and returns image/PDF assets as short-lived pre-signed URLs generated against object storage. Write operations (create, update, delete) bypass the cache and target the PostgreSQL primary, which replicates asynchronously to the replica.

Students implement the routing logic in a small FastAPI service, then intentionally stress the write path to produce measurable replication lag, observe it through database monitoring views, and finally trigger a primary failover to confirm the replica is promoted and the API resumes serving traffic within an acceptable window.

## Architecture overview

- **FastAPI service** — single Python container; implements `GET /products/{id}`, `POST /products`, `PUT /products/{id}`, `DELETE /products/{id}`
- **Redis cache** (Azure Cache for Redis / Amazon ElastiCache for Redis) — key `product:{id}`, TTL 60 seconds; cache-aside pattern; populated on cache miss, invalidated on write
- **PostgreSQL primary** (Azure Database for PostgreSQL Flexible Server / Amazon RDS for PostgreSQL) — receives all INSERT / UPDATE / DELETE statements
- **PostgreSQL read replica** — receives all SELECT statements via a separate connection string; asynchronous streaming replication from the primary
- **Object storage** (Azure Blob Storage / Amazon S3) — stores `images/{id}.jpg` and `datasheets/{id}.pdf`; the API generates pre-signed URLs (SAS tokens on Azure, presigned URLs on AWS) with a 15-minute expiry and returns them in the JSON response body
- **Virtual network / VPC** — all managed data services are placed on private endpoints or inside a private subnet; the FastAPI container is the only component with a public-facing endpoint
- **Terraform** — provisions all cloud resources; connection strings and keys are passed to the container via environment variables sourced from Key Vault / Secrets Manager references in the Terraform output

## Cloud resources to provision (via Terraform)

| Resource | Azure equivalent | AWS equivalent |
|---|---|---|
| Virtual network with subnets | Azure Virtual Network + subnets | AWS VPC + subnets |
| Cache cluster | Azure Cache for Redis (Basic C1 or Standard C1) | Amazon ElastiCache for Redis (cache.t3.micro) |
| Relational DB primary | Azure Database for PostgreSQL Flexible Server (GP_Standard_D2s_v3, public access + IP firewall) | Amazon RDS for PostgreSQL (db.t3.micro) |
| Relational DB read replica | PostgreSQL Flexible Server read replica in same region (same SKU) | RDS Read Replica in same region |
| Object storage bucket / container | Azure Blob Storage (StorageV2, LRS) | Amazon S3 bucket |
| Private network access for Redis | Private Endpoint for Redis | ElastiCache subnet group + security group (no public access) |
| PostgreSQL access control | IP firewall rule restricting access to student laptop IP (public access mode) | RDS subnet group + security group (no public access) |
| Private network access for object storage | Private Endpoint for Blob Storage | S3 VPC Gateway Endpoint |
| Container registry | Azure Container Registry (Basic SKU) | Amazon ECR (private repository) |
| Container runtime | Azure Container Instances (public IP, 0.5 vCPU / 1 GB) | AWS App Runner or ECS Fargate (single task) |
| Secrets store | Azure Key Vault | AWS Secrets Manager |

## Exercise tasks

1. **Provision infrastructure and deploy the container.**
   Run `terraform init && terraform plan && terraform apply` from `homeworks/module5/terraform_az/`. Then build and push the Docker image to ACR (`az acr login`, `docker build`, `docker push`), set `container_image` in `terraform.tfvars`, and run `terraform apply` again to create the ACI container. Confirm the API is reachable at `terraform output -raw api_url`.

2. **Implement the cache-aside pattern.**
   In `src/lesson05_catalog/main.py`, complete the `get_product` handler so that it: (a) checks Redis for key `product:{id}`; (b) on a hit, returns the cached JSON and sets a response header `X-Cache: HIT`; (c) on a miss, queries the PostgreSQL read replica, writes the result to Redis with `EX 60`, and sets `X-Cache: MISS`. Confirm behavior with `curl -v GET /products/1` twice in succession and observe the header change.

3. **Verify read/write routing.**
   Add a log line to each database call that records which host (primary vs. replica FQDN) was used. Issue five `POST /products` requests and five `GET /products/{id}` requests (after clearing Redis with `FLUSHALL`). Inspect the container logs to confirm all writes hit the primary host and all DB reads hit the replica host.

4. **Measure replication lag under write load.**
   Run the provided load script (`scripts/write_load.sh`, 200 INSERT statements in rapid succession) against the primary. While the script runs, query `pg_stat_replication` on the primary (Azure) or the `ReplicaLag` CloudWatch metric (AWS) and record the peak lag value in seconds. Include the query output or a screenshot in your submission.

5. **Upload assets to object storage and return pre-signed URLs.**
   Using the Terraform-provisioned storage account/bucket, upload `sample_image.jpg` and `sample_datasheet.pdf` for product ID 1 using the Azure CLI (`az storage blob upload`) or AWS CLI (`aws s3 cp`). Implement the `build_asset_urls(product_id)` helper in `main.py` to generate SAS tokens (Azure) or presigned URLs (AWS) with a 15-minute expiry, and verify that the URLs in the `GET /products/1` response body are accessible in a browser and expire after 15 minutes.

6. **Simulate primary failover and measure recovery time.**
   Azure: Promote the read replica to a standalone server using `az postgres flexible-server replica promote --promote-mode standalone --promote-option forced`. AWS: Use `aws rds failover-db-instance`. Record the time between the failover trigger and the moment `GET /products/1` returns HTTP 200 again (the replica must have been promoted and the application reconnected). The API must not require a manual restart; implement connection retry logic with exponential backoff (max 5 retries, 2-second base delay) in the database connection setup.

7. **Write a Terraform module for the PostgreSQL resource pair.**
   Refactor the PostgreSQL primary + replica resources into a reusable module at `homeworks/module5/terraform/modules/postgres_with_replica/`. The module must expose input variables `location`, `resource_group_name` (Azure) or `vpc_id`, `subnet_ids` (AWS), `db_name`, `db_username`, `db_password`, and output variables `primary_fqdn`, `replica_fqdn`. Call the module from the root module and confirm `terraform validate` and `terraform plan` succeed without errors.

## Acceptance criteria

- `terraform apply` completes with zero errors and all resources are visible in the Azure portal or AWS console
- `psql` from the student's laptop connects to the PostgreSQL primary FQDN on port 5432 (public access, IP firewall); `Test-NetConnection` on Redis port 6380 succeeds (public access enabled, TLS + password required)
- The API responds at `terraform output -raw api_url` (ACI public FQDN, port 8000)
- Two consecutive `GET /products/{id}` requests return `X-Cache: MISS` on the first call and `X-Cache: HIT` on the second call, confirmed by response headers
- Container logs show zero SELECT statements directed to the primary host during normal GET traffic (all reads go to the replica FQDN)
- A `pg_stat_replication` query or CloudWatch `ReplicaLag` metric captured during the write load test is included in the submission; any lag value is acceptable as long as it is non-zero and the measurement was taken during active load
- Pre-signed/SAS URLs for the image and PDF are present in the `GET /products/1` JSON response, return HTTP 200 when fetched within 15 minutes, and return HTTP 403 or HTTP 404 after expiry
- After a primary failover, `GET /products/{id}` returns HTTP 200 within 60 seconds of the failover trigger, without a manual container restart
- `terraform validate` passes on the `postgres_with_replica` module, and `terraform plan` shows the module used in the root configuration with no errors
