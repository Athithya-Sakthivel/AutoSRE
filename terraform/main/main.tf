# ------------------------------------------------------------------------------
# Data sources
# ------------------------------------------------------------------------------
data "azurerm_subscription" "current" {}
data "azuread_client_config" "current" {}

# ------------------------------------------------------------------------------
# Resource group – all resources will be placed here
# ------------------------------------------------------------------------------
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ------------------------------------------------------------------------------
# Module: state (Cosmos DB + ACR)
# ------------------------------------------------------------------------------
module "state" {
  source = "./modules/state"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags

  cosmosdb_account_name             = var.cosmosdb_account_name
  cosmosdb_offer_type               = var.cosmosdb_offer_type
  cosmosdb_enable_free_tier         = var.cosmosdb_enable_free_tier
  cosmosdb_throughput               = var.cosmosdb_throughput
  cosmosdb_autoscale_max_throughput = null # not using autoscale

  acr_name = var.acr_name
  acr_sku  = var.acr_sku
}