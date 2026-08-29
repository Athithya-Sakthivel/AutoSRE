# ==============================================================================
# modules/postgresql/main.tf
#
# PostgreSQL Flexible Server architecture:
#
#   - PostgreSQL 16
#   - B_Standard_B1ms
#   - 32 GiB initial storage
#   - Single node / no HA
#   - Public network access disabled
#   - Access through Azure Private Link private endpoint
#   - Private DNS zone integration supplied by networking module
#   - Administrator password supplied through Key Vault -> ephemeral variable
#     -> AzureRM write-only password attribute
# ==============================================================================

# ------------------------------------------------------------------------------
# PostgreSQL Flexible Server
#
# This server uses Azure's public-access networking mode with public network
# access disabled and a Private Endpoint for private connectivity.
#
# IMPORTANT:
# Do NOT set delegated_subnet_id or the server's private_dns_zone_id here.
# Those arguments are for VNet-integrated/private-access Flexible Servers.
# The locked design uses Private Link instead.
# ------------------------------------------------------------------------------
resource "azurerm_postgresql_flexible_server" "this" {
  name                = var.server_name
  resource_group_name = var.resource_group_name
  location            = var.location

  version    = var.postgresql_version
  sku_name   = var.sku_name
  storage_mb = var.storage_mb

  administrator_login = var.administrator_login

  # AzureRM 5.2.0 write-only password support.
  #
  # The password itself is not persisted as a normal resource attribute.
  # administrator_password_wo_version must change when the password rotates.
  administrator_password_wo         = var.administrator_password
  administrator_password_wo_version = var.administrator_password_version

  backup_retention_days = var.backup_retention_days

  # Locked design: public network access is disabled.
  # Connectivity is provided through azurerm_private_endpoint.postgresql.
  public_network_access_enabled = false

  # No high_availability block:
  # AzureRM 5.2.0 accepts only SameZone or ZoneRedundant when the block exists.
  # Omitting the block keeps this server single-node / non-HA.

  tags = var.tags

  # Prevent Terraform from trying to change availability zone after failover
  lifecycle {
    ignore_changes = [
      zone,
      high_availability,
    ]
  }


}

# ------------------------------------------------------------------------------
# Application database
# ------------------------------------------------------------------------------
resource "azurerm_postgresql_flexible_server_database" "this" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.this.id

  charset   = "UTF8"
  collation = "en_US.utf8"
}

# ------------------------------------------------------------------------------
# PostgreSQL Private Endpoint
#
# PostgreSQL Flexible Server Private Link uses the "postgresqlServer"
# subresource.
# ------------------------------------------------------------------------------
resource "azurerm_private_endpoint" "postgresql" {
  name                = "pe-${var.server_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-${var.server_name}"
    private_connection_resource_id = azurerm_postgresql_flexible_server.this.id
    is_manual_connection           = false
    subresource_names              = ["postgresqlServer"]
  }

  # AzureRM 5.2.0 uses this nested block on azurerm_private_endpoint.
  #
  # This integrates the endpoint with the Private DNS zone supplied by the
  # networking module. The networking module remains responsible for linking
  # that Private DNS zone to the appropriate VNet.
  private_dns_zone_group {
    name                 = "postgresql-dns-zone-group"
    private_dns_zone_ids = [var.private_dns_zone_id]
  }

  tags = var.tags
}
