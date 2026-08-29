# ==============================================================================
# modules/postgresql/outputs.tf
# Outputs for the PostgreSQL Flexible Server module.
# ==============================================================================

output "server_id" {
  description = "Azure resource ID of the PostgreSQL Flexible Server."
  value       = azurerm_postgresql_flexible_server.this.id
}

output "server_name" {
  description = "Name of the PostgreSQL Flexible Server."
  value       = azurerm_postgresql_flexible_server.this.name
}

output "server_fqdn" {
  description = "Fully qualified domain name of the PostgreSQL Flexible Server."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "database_name" {
  description = "Name of the database created on the PostgreSQL Flexible Server."
  value       = azurerm_postgresql_flexible_server_database.this.name
}

output "private_endpoint_id" {
  description = "Azure resource ID of the PostgreSQL private endpoint."
  value       = azurerm_private_endpoint.postgresql.id
}

output "private_endpoint_private_ip" {
  description = "Private IP address assigned to the PostgreSQL private endpoint."
  value       = azurerm_private_endpoint.postgresql.private_service_connection[0].private_ip_address
}
