# ------------------------------------------------------------------------------
# Bootstrap Key Vault
#
# Holds secrets that pipelines fetch at runtime.  Nothing is stored in
# Azure DevOps variable groups as a secret.
# ------------------------------------------------------------------------------

resource "azurerm_key_vault" "bootstrap" {
  name                       = "kv-${var.project_name}"
  location                   = var.location
  resource_group_name        = var.state_rg
  tenant_id                  = data.azuread_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  rbac_authorization_enabled = true
}

# ------------------------------------------------------------------------------
# Secrets
# ------------------------------------------------------------------------------

resource "azurerm_key_vault_secret" "azdo_pat" {
  name         = "azdo-pat"
  value        = var.azdo_personal_access_token
  key_vault_id = azurerm_key_vault.bootstrap.id

  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_key_vault_secret" "rollback_webhook" {
  count = var.rollback_webhook_url != "" ? 1 : 0

  name         = "rollback-webhook"
  value        = var.rollback_webhook_url
  key_vault_id = azurerm_key_vault.bootstrap.id

  lifecycle {
    ignore_changes = [value]
  }
}