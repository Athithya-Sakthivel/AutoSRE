# ==============================================================================
# state/outputs.tf – Output values for the state module
# ==============================================================================

output "resource_group_name" {
  description = "Name of the resource group that holds all platform resources."
  value       = azurerm_resource_group.this.name
}

output "resource_group_id" {
  description = "ARM resource ID of the resource group."
  value       = azurerm_resource_group.this.id
}

output "acr_name" {
  description = "Name of the Azure Container Registry."
  value       = azurerm_container_registry.this.name
}

output "acr_id" {
  description = "ARM resource ID of the Azure Container Registry."
  value       = azurerm_container_registry.this.id
}

output "acr_login_server" {
  description = "Login server URL of the Azure Container Registry."
  value       = azurerm_container_registry.this.login_server
}

output "acr_admin_username" {
  description = "Admin username for ACR (if enabled). Usually empty because admin is disabled."
  value       = var.acr_admin_enabled ? azurerm_container_registry.this.admin_username : null
  sensitive   = true
}

output "acr_admin_password" {
  description = "Admin password for ACR (if enabled). Usually empty because admin is disabled."
  value       = var.acr_admin_enabled ? azurerm_container_registry.this.admin_password : null
  sensitive   = true
}
