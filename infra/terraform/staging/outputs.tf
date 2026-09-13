output "resource_group_name" {
  value = data.azurerm_resource_group.staging.name
}

output "location" {
  value = data.azurerm_resource_group.staging.location
}

output "key_vault_name" {
  value = azapi_resource.key_vault.name
}

output "key_vault_uri" {
  value = azapi_resource.key_vault.output.properties.vaultUri
}

output "engineer_object_id" {
  value = data.azurerm_client_config.current.object_id
}
