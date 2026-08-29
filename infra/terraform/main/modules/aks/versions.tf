# ==============================================================================
# modules/aks/versions.tf – Provider requirements for the AKS module
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
