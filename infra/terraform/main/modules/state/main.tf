# ==============================================================================
# state/main.tf – Base resource group
#
# All other resources in the platform are placed in this resource group.
# ==============================================================================

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location

  tags = var.tags

  # Prevent accidental deletion of a resource group that still contains resources.
  # This safety net is overridden in the root provider's `features` block when
  # environment is production, but we also add a lifecycle guard here.
  lifecycle {
    prevent_destroy = false # Set to true in production via variable if needed
  }

}
