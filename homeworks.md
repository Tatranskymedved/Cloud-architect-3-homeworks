# Homeworks

Each module is self-contained in its own folder. Each folder contains a generic definition file and an Azure-specific implementation guide.

---

## ⚠️ Ground rules for working with this repo

> **Git:** Never create a worktree or worktree branches.

> **GitHub Actions:** Always warn before running any GitHub Actions workflow — do not trigger them without explicit confirmation.

> **Datacenters:** Always provision resources in **European regions**. Use `eu-west-1` (Ireland) for AWS and `westeurope` (Netherlands) for Azure as the default. Regions `eu-west-2` (London) and `eu-west-3` (Paris) are acceptable alternatives. Never provision homework infrastructure in US or Asia-Pacific regions. Note: ECR Public (AWS container registry) is a global service whose control plane lives in `us-east-1` — this is an AWS service constraint, not an infrastructure region choice; your actual workloads still run in `eu-west-1`.

---

## [Module 2: Compute](module2/)

VM to serverless + orchestrating containers

- [Definition](module2/module2_compute.md)
- [Azure implementation](module2/module2_compute_azure.md)

---

## [Module 3: Networking](module3/)

Split load and getting traffic + enterprise networking

- [Definition](module3/module3_networking.md)
- [Azure implementation](module3/module3_networking_azure.md)

---

## [Module 4: Application patterns](module4/)

Design patterns of modern apps + Monitoring modern apps

- [Definition](module4/module4_application_patterns.md)
- [Azure implementation](module4/module4_application_patterns_azure.md)

---

## [Module 5: Persistent layer](module5/)

Types of data storages and performance aspects + redundancy and distribution of data, availability vs consistency

- [Definition](module5/module5_persistent_layer.md)
- [Azure implementation](module5/module5_persistent_layer_azure.md)
