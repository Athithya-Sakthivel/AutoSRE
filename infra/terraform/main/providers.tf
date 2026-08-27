provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = var.environment == "prod"
    }
    key_vault {
      recover_soft_deleted_key_vaults = true
      purge_soft_delete_on_destroy    = true
    }
  }

  subscription_id     = var.subscription_id
  tenant_id           = var.tenant_id
  storage_use_azuread = true
}

provider "azuread" {
  tenant_id = var.tenant_id
}

# Authenticated via environment variables:
# AZDO_ORG_SERVICE_URL and AZDO_PERSONAL_ACCESS_TOKEN
provider "azuredevops" {}