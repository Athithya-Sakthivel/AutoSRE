# ============================================================================
# modules/observability/main.tf
# Azure Monitor backing resources.
#
# Application Insights is workspace-based and uses the Log Analytics workspace
# as its storage backend. The Java agent only needs the resulting connection
# string at runtime; Terraform does not instrument the application.
# ============================================================================

resource "azurerm_log_analytics_workspace" "this" {
  name                = var.log_analytics_workspace_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days

  tags = var.tags
}

resource "azurerm_application_insights" "this" {
  name                = var.application_insights_name
  location            = var.location
  resource_group_name = var.resource_group_name
  application_type    = "web"

  # Workspace-based Application Insights.
  workspace_id = azurerm_log_analytics_workspace.this.id

  # Keep server-side ingestion sampling at 100%; application-side sampling
  # remains under the Java agent/runtime configuration.
  sampling_percentage = 100

  tags = var.tags
}
