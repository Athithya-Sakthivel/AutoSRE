output "cosmosdb_account_id" {
  value = module.state.cosmosdb_account_id
}

output "cosmosdb_endpoint" {
  value = module.state.cosmosdb_account_endpoint
}

output "cosmosdb_primary_key" {
  value     = module.state.cosmosdb_primary_key
  sensitive = true
}

output "cosmosdb_connection_string" {
  value     = module.state.cosmosdb_primary_connection_string
  sensitive = true
}

output "acr_id" {
  value = module.state.acr_id
}

output "acr_login_server" {
  value = module.state.acr_login_server
}