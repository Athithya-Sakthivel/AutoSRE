# ------------------------------------------------------------------------------
# Azure Machine Learning Workspace
#
# Provisions:
#   - A dedicated storage account (HNS disabled – AML requirement)
#   - The ML workspace itself (linked to an external Key Vault)
#
# Key Vault is now managed by the central `key_vault` module.
# ------------------------------------------------------------------------------

resource "azurerm_storage_account" "ml" {
  name                     = var.ml_storage_account_name
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  is_hns_enabled           = false

  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false

  tags = var.tags
}

resource "azurerm_machine_learning_workspace" "this" {
  name                    = var.workspace_name
  location                = var.location
  resource_group_name     = var.resource_group_name
  application_insights_id = var.application_insights_id
  key_vault_id            = var.key_vault_id # external, central Key Vault
  storage_account_id      = azurerm_storage_account.ml.id
  container_registry_id   = var.container_registry_id

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags

  # Azure ML auto‑creates role assignments for the workspace identity on the
  # linked storage, key vault, and container registry.  Do NOT define those
  # assignments here – they would cause 409 conflicts.
}

# Additional role: workspace identity on the *data lake* storage (not the
# workspace’s own storage).  This one is not auto‑created by Azure ML.
resource "azurerm_role_assignment" "workspace_datalake_blob" {
  scope                = var.datalake_storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_machine_learning_workspace.this.identity[0].principal_id
}
