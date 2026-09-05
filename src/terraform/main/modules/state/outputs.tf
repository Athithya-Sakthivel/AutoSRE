# ------------------------------------------------------------------------------
# Cosmos DB outputs
# ------------------------------------------------------------------------------
output "cosmosdb_account_id" {
  description = "Resource ID of the Cosmos DB account."
  value       = azurerm_cosmosdb_account.main.id
}

output "cosmosdb_account_endpoint" {
  description = "Cosmos DB account endpoint (URI)."
  value       = azurerm_cosmosdb_account.main.endpoint
}

output "cosmosdb_primary_key" {
  description = "Primary read‑write key for the Cosmos DB account."
  value       = azurerm_cosmosdb_account.main.primary_key
  sensitive   = true
}

output "cosmosdb_primary_connection_string" {
  description = "Primary connection string for Cosmos DB (AccountEndpoint + AccountKey)."
  value       = "AccountEndpoint=${azurerm_cosmosdb_account.main.endpoint};AccountKey=${azurerm_cosmosdb_account.main.primary_key};"
  sensitive   = true
}

output "database_name" {
  description = "Name of the SQL database."
  value       = azurerm_cosmosdb_sql_database.main.name
}

output "checkpoint_container_name" {
  description = "Name of the checkpoints container."
  value       = azurerm_cosmosdb_sql_container.checkpoints.name
}

output "rate_limit_container_name" {
  description = "Name of the rate‑limits container."
  value       = azurerm_cosmosdb_sql_container.rate_limits.name
}

# ------------------------------------------------------------------------------
# ACR outputs
# ------------------------------------------------------------------------------
output "acr_id" {
  description = "Resource ID of the Azure Container Registry."
  value       = azurerm_container_registry.main.id
}

output "acr_login_server" {
  description = "Login server (hostname) for the ACR (e.g., myacr.azurecr.io)."
  value       = azurerm_container_registry.main.login_server
}