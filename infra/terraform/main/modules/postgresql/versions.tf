# ==============================================================================
# modules/postgresql/versions.tf
# Provider requirements for the PostgreSQL Flexible Server module.
#
# Designed for OpenTofu 1.12+ and AzureRM 5.2.0.
# ==============================================================================
# ==============================================================================
# postgres/versions.tf – Provider requirements for the PostgreSQL module
# ==============================================================================

terraform {
  required_version = ">= 1.12.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 5.2.0"
    }
  }
}
