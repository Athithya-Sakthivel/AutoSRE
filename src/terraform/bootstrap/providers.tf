terraform {
  required_version = ">= 1.12.0, < 2.0.0"

  backend "azurerm" {}

  required_providers {
    azuredevops = {
      source  = "microsoft/azuredevops"
      version = "= 1.15.1"
    }

    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.53"
    }

    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 4.0.0"
    }
  }
}

variable "azurerm_subscription_id" {
  type        = string
  description = "Azure subscription ID for the bootstrap provider."
}

variable "azurerm_tenant_id" {
  type        = string
  description = "Azure tenant ID for the bootstrap provider."
}

provider "azurerm" {
  features {}

  subscription_id = var.azurerm_subscription_id
  tenant_id       = var.azurerm_tenant_id
  use_cli         = true
}