# ------------------------------------------------------------------------------
# Bootstrap Key Vault
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


  # network_acls {
  #  bypass         = "AzureServices"
  #  default_action = "Deny"
  # }
  # network_acls are disabled for one shot automation. kv is still protected by RBAC.


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

resource "azurerm_key_vault_secret" "database_username" {
  name         = "DatabaseUsername"
  value        = var.database_username
  key_vault_id = azurerm_key_vault.bootstrap.id

  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_key_vault_secret" "database_password" {
  name         = "DatabasePassword"
  value        = var.database_password
  key_vault_id = azurerm_key_vault.bootstrap.id

  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_key_vault_secret" "jwt_secret" {
  name         = "JwtSecret"
  value        = var.jwt_secret
  key_vault_id = azurerm_key_vault.bootstrap.id

  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_key_vault_secret" "cloudflare_tunnel_token" {
  name         = "CloudflareTunnelToken"
  value        = var.cloudflare_tunnel_token
  key_vault_id = azurerm_key_vault.bootstrap.id

  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_key_vault_secret" "cloudflare_tunnel_name" {
  name         = "CloudflareTunnelName"
  value        = var.cloudflare_tunnel_name
  key_vault_id = azurerm_key_vault.bootstrap.id
}

resource "azurerm_key_vault_secret" "cloudflare_tunnel_id" {
  name         = "CloudflareTunnelId"
  value        = var.cloudflare_tunnel_id
  key_vault_id = azurerm_key_vault.bootstrap.id
}

resource "azurerm_key_vault_secret" "origin_cert" {
  name         = "OriginCaCert"
  value        = var.origin_cert
  key_vault_id = azurerm_key_vault.bootstrap.id

  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_key_vault_secret" "origin_key" {
  name         = "OriginCaKey"
  value        = var.origin_key
  key_vault_id = azurerm_key_vault.bootstrap.id

  lifecycle {
    ignore_changes = [value]
  }
}
