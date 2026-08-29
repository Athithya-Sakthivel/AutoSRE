# ==============================================================================
# state/acr.tf – Azure Container Registry
#
# The ACR stores container images for the backend and frontend services.
# Access is via managed identity / workload identity, not admin credentials and so ignore_changes not required
# ==============================================================================

resource "azurerm_container_registry" "this" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = var.acr_sku
  admin_enabled       = var.acr_admin_enabled

  tags = var.tags

}
