# ==============================================================================
# modules/function/storage.tf
#
# Dedicated storage account for the Flex Consumption Function App.
# Shared-key access must be enabled because the Function App is configured
# with storage_authentication_type = "StorageAccountConnectionString",
# which requires a non‑empty primary_access_key.
# ==============================================================================

resource "azurerm_storage_account" "this" {
  name                     = var.storage_account_name
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  # Required for StorageAccountConnectionString authentication
  shared_access_key_enabled = true

  tags = var.tags
}

resource "azurerm_storage_container" "deploymentpackage" {
  name                  = var.deployment_container_name
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}
