# ==============================================================================
# versions.tf – Terraform and provider version constraints
#
# This file pins all providers to exact versions to ensure reproducible
# deployments. The root module declares the backend and all providers used
# by modules. Individual modules declare only the providers they use.
#
# Required Terraform/OpenTofu version: >= 1.12.0
# ==============================================================================

terraform {
  # Minimum OpenTofu/Terraform version
  required_version = ">= 1.12.0, < 2.0.0"

  # ---------------------------------------------------------------------------
  # Backend configuration
  # The actual values are provided dynamically via backend-config in run.sh
  # or Azure Pipelines. The backend block is empty here because the values
  # differ between local (CLI), CI/CD (OIDC), and access key auth modes.
  # ---------------------------------------------------------------------------
  backend "azurerm" {}

  # ---------------------------------------------------------------------------
  # Required providers
  # All pinned to exact versions for reproducibility.
  # ---------------------------------------------------------------------------
  required_providers {
    # Azure Resource Manager – main infrastructure provider
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 5.2.0" # Latest stable as of August 2026
    }

    # Azure Active Directory – for workload identity, role assignments
    azuread = {
      source  = "hashicorp/azuread"
      version = "= 3.9.0"
    }

    # Azure DevOps – for pipelines and variable groups
    azuredevops = {
      source  = "microsoft/azuredevops"
      version = "= 1.16.0"
    }

    # Random – for generating unique suffixes if needed
    random = {
      source  = "hashicorp/random"
      version = "= 3.7.1"
    }

  }
}
