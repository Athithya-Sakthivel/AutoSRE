# ============================================================================
# modules/observability/outputs.tf
# Outputs consumed by the application/platform layer.
# ============================================================================

output "log_analytics_workspace_id" {
  description = "ARM resource ID of the Log Analytics workspace."
  value       = azurerm_log_analytics_workspace.this.id
}

output "log_analytics_workspace_name" {
  description = "Name of the Log Analytics workspace."
  value       = azurerm_log_analytics_workspace.this.name
}

output "log_analytics_workspace_customer_id" {
  description = "Log Analytics workspace/customer ID used by workspace-aware tooling."
  value       = azurerm_log_analytics_workspace.this.workspace_id
}

output "application_insights_id" {
  description = "ARM resource ID of the Application Insights component."
  value       = azurerm_application_insights.this.id
}

output "application_insights_name" {
  description = "Name of the Application Insights component."
  value       = azurerm_application_insights.this.name
}

output "application_insights_app_id" {
  description = "Application Insights App ID."
  value       = azurerm_application_insights.this.app_id
}

output "application_insights_connection_string" {
  description = "Sensitive Application Insights connection string for the Java agent runtime configuration."
  value       = azurerm_application_insights.this.connection_string
  sensitive   = true
}

output "application_insights_instrumentation_key" {
  description = "Sensitive legacy Application Insights instrumentation key. Prefer the connection string for new deployments."
  value       = azurerm_application_insights.this.instrumentation_key
  sensitive   = true
}

output "action_group_id" {
  description = "ARM resource ID of the Azure Monitor action group used by alerts."
  value       = azurerm_monitor_action_group.this.id
}

output "workbook_id" {
  description = "ARM resource ID of the Azure Monitor workbook."
  value       = azurerm_application_insights_workbook.this.id
}
