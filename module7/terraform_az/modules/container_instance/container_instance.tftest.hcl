# terraform test for the container_instance module.
# Run from the module directory:
#   terraform test -chdir=homeworks/module7/terraform_az/modules/container_instance/
#
# Uses command = plan (default) — no real infrastructure is created, no Azure cost incurred.

run "staging_cpu_and_memory" {
  command = plan

  variables {
    name                = "testprefix-staging"
    location            = "westeurope"
    resource_group_name = "rg-test-quoteapi"
    image               = "testprefix-acr.azurecr.io/quote-api:latest"
    cpu                 = 0.5
    memory              = 0.5
    port                = 8000
    # secure_environment_variables intentionally omitted — defaults to {}
    # dynamic image_registry_credential block is skipped when ACR_PASSWORD is absent
  }

  assert {
    condition     = output.cpu == 0.5
    error_message = "Staging cpu must be 0.5 vCPU; got ${output.cpu}"
  }

  assert {
    condition     = output.memory == 0.5
    error_message = "Staging memory must be 0.5 GB; got ${output.memory}"
  }
}
