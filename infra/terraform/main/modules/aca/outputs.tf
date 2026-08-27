# ==============================================================================
# modules/aca/outputs.tf
#
# Only the environment is exported.  The serving app and training job are
# created by run.sh via Azure CLI and their IDs are derived in the script
# using the same naming convention (derive_names function).
# ==============================================================================

output "environment_name" {
  description = "Name of the ACA managed environment."
  value       = azurerm_container_app_environment.this.name
}

output "environment_id" {
  description = "ARM resource ID of the ACA managed environment."
  value       = azurerm_container_app_environment.this.id
}