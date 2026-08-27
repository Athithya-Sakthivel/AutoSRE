terraform {
  required_version = ">= 1.12.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 4.80.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "= 3.9.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "= 2.10.0"
    }
  }
}