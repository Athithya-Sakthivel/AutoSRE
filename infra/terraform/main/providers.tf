# ==============================================================================
# providers.tf – Provider configuration
#
# Authentication is handled via environment variables or OIDC, not hardcoded
# credentials. The AzureRM provider uses subscription and tenant IDs passed
# as variables (exported by run.sh or Azure Pipelines).
#
# Environment variables used:
#   ARM_CLIENT_ID        – Service principal client ID (OIDC)
#   ARM_TENANT_ID        – Tenant ID (OIDC)
#   ARM_OIDC_TOKEN       – OIDC token (OIDC)
#   ARM_SUBSCRIPTION_ID  – Subscription ID
#   ARM_USE_OIDC         – Set to "true" for OIDC auth
#
# For local development with Azure CLI:
#   ARM_USE_CLI = "true"
#
# For access key auth (bootstrap only):
#   ARM_ACCESS_KEY = "<storage-account-key>"
# ==============================================================================

# ------------------------------------------------------------------------------
# Azure Resource Manager provider
# ------------------------------------------------------------------------------
provider "azurerm" {
  features {
    # Prevent accidental deletion of resource groups containing resources
    resource_group {
      prevent_deletion_if_contains_resources = var.environment == "prod"
    }

    # Key Vault settings
    key_vault {
      recover_soft_deleted_key_vaults = true
      purge_soft_delete_on_destroy    = true
    }
  }

  # ---------------------------------------------------------------------------
  # Resource provider registration
  # AzureRM 5.x defaults to registering no resource providers automatically.
  # We explicitly register all providers required by our modules.
  # ---------------------------------------------------------------------------
  resource_provider_registrations = "none"
  resource_providers_to_register = [
    "Microsoft.Network",             # VNet, subnets, NSGs, NAT Gateway, private endpoints
    "Microsoft.ContainerService",    # AKS
    "Microsoft.ContainerRegistry",   # ACR
    "Microsoft.DBforPostgreSQL",     # PostgreSQL Flexible Server
    "Microsoft.OperationalInsights", # Log Analytics workspace
    "Microsoft.Insights",            # Application Insights, alerts
    "Microsoft.Consumption",         # Budget and cost management
    "Microsoft.Authorization",       # Role assignments
  ]

  # Subscription and tenant from variables (exported by run.sh)
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  # Use Azure AD for storage authentication
  storage_use_azuread = true
}

# ------------------------------------------------------------------------------
# Azure Active Directory provider
# For workload identity, role assignments, and Entra ID operations
# ------------------------------------------------------------------------------
provider "azuread" {
  tenant_id = var.tenant_id
}

# ------------------------------------------------------------------------------
# Azure DevOps provider
# Authenticated via environment variables:
#   AZDO_ORG_SERVICE_URL
#   AZDO_PERSONAL_ACCESS_TOKEN
# These are set by run.sh or Azure Pipelines before Terraform runs.
# ------------------------------------------------------------------------------
provider "azuredevops" {
  # org_service_url and personal_access_token are read from environment:
  # AZDO_ORG_SERVICE_URL and AZDO_PERSONAL_ACCESS_TOKEN
  # No hardcoded values here.
}

# ------------------------------------------------------------------------------
# Random provider
# Used for generating unique identifiers when needed (e.g., passwords)
# ------------------------------------------------------------------------------
provider "random" {
  # No configuration needed
}
