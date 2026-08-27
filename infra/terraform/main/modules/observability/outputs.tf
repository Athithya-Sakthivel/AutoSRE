output "log_analytics_workspace_name" {
  value = azurerm_log_analytics_workspace.this.name
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.this.id
}

output "application_insights_name" {
  value = azurerm_application_insights.this.name
}

output "application_insights_id" {
  value = azurerm_application_insights.this.id
}

output "application_insights_connection_string" {
  value     = azurerm_application_insights.this.connection_string
  sensitive = true
}

output "application_insights_instrumentation_key" {
  value     = azurerm_application_insights.this.instrumentation_key
  sensitive = true
}

output "workbook_id" {
  value = azurerm_application_insights_workbook.this.id
}

output "workbook_name" {
  value = azurerm_application_insights_workbook.this.name
}

output "action_group_id" {
  value = azurerm_monitor_action_group.this.id
}