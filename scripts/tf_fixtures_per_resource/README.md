# scripts/tf_fixtures_per_resource — per-resource-type terraform probe
# fixtures (v26.10.19 re-author).
#
# Re-authored fresh (not byte-copied) after test/terraform_fixture_per_resource
# was deleted at 64f6099. Semantic contracts preserved from the predecessor:
# provider pins (azurerm = 4.54.0, tf >= 1.8.5), the smalt-local location,
# all-zero tenant/subscription ids, and the per-probe resource naming scheme
# (rg-smalt-tf-probe-*, t5-prefixed storage/namespace names).
#
# One .tf per admitted ARM resource family the checker exercises:
#   rg.tf          azurerm_resource_group
#   keyvault.tf    azurerm_key_vault
#   storage.tf     azurerm_storage_account + azurerm_storage_container
#   cosmos.tf      azurerm_cosmosdb_account/_sql_database/_sql_container
#   eventhub.tf    azurerm_eventhub_namespace + azurerm_eventhub
#   servicebus.tf  azurerm_servicebus_namespace + azurerm_servicebus_queue
#
# Consumed by scripts/tf_plan_check.sh: versions.tf + <name>.tf are staged
# into a temp dir per fixture (init + plan + apply + refresh-only plan).
# The guard at tf_plan_check.sh:208 refuses to run when this family is absent,
# so the directory's existence is itself a gate input — keep versions.tf here.
#
# Local lint without touching the probe:
#   terraform fmt -check scripts/tf_fixtures_per_resource  (syntax only)
# Full init needs the provider; scripts/tf_plan_check.sh provisions it via
# scripts/tf_mirror_env.sh (falls through to registry when offline).
