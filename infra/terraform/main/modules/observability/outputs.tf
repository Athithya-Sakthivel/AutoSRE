output "log_analytics_workspace_id" {
  description = "ARM resource ID of the Log Analytics workspace."
  value       = azurerm_log_analytics_workspace.this.id
}

output "log_analytics_workspace_name" {
  description = "Name of the Log Analytics workspace."
  value       = azurerm_log_analytics_workspace.this.name
}

output "log_analytics_workspace_customer_id" {
  description = "Workspace/customer GUID of the Log Analytics workspace."
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
  description = "Application Insights application ID."
  value       = azurerm_application_insights.this.app_id
}

output "application_insights_connection_string" {
  description = "Application Insights connection string."
  value       = azurerm_application_insights.this.connection_string
  sensitive   = true
}

output "application_insights_instrumentation_key" {
  description = "Legacy Application Insights instrumentation key."
  value       = azurerm_application_insights.this.instrumentation_key
  sensitive   = true
}

output "action_group_id" {
  description = "ARM resource ID of the Azure Monitor action group."
  value       = azurerm_monitor_action_group.this.id
}

output "workbook_id" {
  description = "ARM resource ID of the Azure Monitor workbook."
  value       = azurerm_application_insights_workbook.this.id
}