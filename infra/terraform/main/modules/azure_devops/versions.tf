terraform {
  required_version = ">= 1.12.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 4.80.0"
    }
    azuredevops = {
      source  = "microsoft/azuredevops"
      version = "= 1.15.1"
    }
  }
}