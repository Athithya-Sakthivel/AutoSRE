# ==============================================================================
# azure_devops/versions.tf – Provider requirements for Azure DevOps module
# ==============================================================================

terraform {
  required_version = ">= 1.12.0, < 2.0.0"

  required_providers {
    azuredevops = {
      source  = "microsoft/azuredevops"
      version = "= 1.16.0"
    }
  }
}
