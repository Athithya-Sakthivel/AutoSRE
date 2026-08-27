resource "azurerm_log_analytics_workspace" "this" {
  name                = var.log_analytics_workspace_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = var.tags
}

resource "azurerm_application_insights" "this" {
  name                = var.application_insights_name
  location            = var.location
  resource_group_name = var.resource_group_name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.this.id
  retention_in_days   = 30

  # Prevents Azure from auto-creating Smart Detector alert rules in the RG
  ip_masking_enabled           = false
  local_authentication_enabled = false
  internet_ingestion_enabled   = true
  internet_query_enabled       = true

  tags = var.tags
}