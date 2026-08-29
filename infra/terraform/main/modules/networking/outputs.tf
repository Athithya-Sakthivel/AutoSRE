# ============================================================================
# networking/outputs.tf - Output values for the networking module
# ============================================================================

output "vnet_id" {
  description = "ARM resource ID of the virtual network."
  value       = azurerm_virtual_network.this.id
}

output "vnet_name" {
  description = "Name of the virtual network."
  value       = azurerm_virtual_network.this.name
}

output "aks_subnet_id" {
  description = "ID of the AKS subnet."
  value       = azurerm_subnet.aks.id
}

output "aks_subnet_name" {
  description = "Name of the AKS subnet."
  value       = azurerm_subnet.aks.name
}

output "pe_subnet_id" {
  description = "ID of the private endpoint subnet."
  value       = azurerm_subnet.pe.id
}

output "pe_subnet_name" {
  description = "Name of the private endpoint subnet."
  value       = azurerm_subnet.pe.name
}

output "reserved_subnet_id" {
  description = "ID of the reserved subnet."
  value       = azurerm_subnet.reserved.id
}

output "reserved_subnet_name" {
  description = "Name of the reserved subnet."
  value       = azurerm_subnet.reserved.name
}

output "aks_nsg_id" {
  description = "ID of the NSG associated with the AKS subnet."
  value       = azurerm_network_security_group.aks.id
}

output "pe_nsg_id" {
  description = "ID of the NSG associated with the private endpoint subnet."
  value       = azurerm_network_security_group.pe.id
}

output "nat_gateway_id" {
  description = "ID of the NAT gateway."
  value       = azurerm_nat_gateway.this.id
}

output "nat_public_ip_id" {
  description = "ID of the public IP address associated with the NAT gateway."
  value       = azurerm_public_ip.nat.id
}

output "nat_public_ip" {
  description = "Public IPv4 address associated with the NAT gateway."
  value       = azurerm_public_ip.nat.ip_address
}

output "private_dns_zone_id" {
  description = "ID of the PostgreSQL private DNS zone."
  value       = azurerm_private_dns_zone.postgres.id
}

output "private_dns_zone_name" {
  description = "Name of the PostgreSQL private DNS zone."
  value       = azurerm_private_dns_zone.postgres.name
}

output "private_dns_zone_link_id" {
  description = "ID of the VNet link for the PostgreSQL private DNS zone."
  value       = azurerm_private_dns_zone_virtual_network_link.postgres.id
}
