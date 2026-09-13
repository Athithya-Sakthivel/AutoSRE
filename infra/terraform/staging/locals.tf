data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "staging" {
  name = var.resource_group_name
}

locals {
  environment = "staging"
  system      = "autosre"

  tags = {
    environment = local.environment
    system      = local.system
    managed_by  = "opentofu"
  }
}
