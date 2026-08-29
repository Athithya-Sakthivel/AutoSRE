# ============================================================================
# modules/observability/versions.tf
# Provider and OpenTofu version requirements.
# ============================================================================

terraform {
  required_version = ">= 1.12.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 5.2.0"
    }
  }
}
