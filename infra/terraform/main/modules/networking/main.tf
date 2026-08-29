# ============================================================================
# networking/main.tf - VNet, subnets, NAT Gateway, NSGs, private DNS zone
#
# Creates:
#   - One virtual network
#   - AKS, private endpoint, and reserved subnets
#   - A Standard NAT Gateway with a static Standard public IP
#   - NSGs for the AKS and private endpoint subnets
#   - PostgreSQL Private DNS zone and a VNet link
#
# The AKS subnet is configured as a private subnet and uses the NAT Gateway
# for explicit outbound connectivity. The AKS cluster itself must use
# outbound_type = "userAssignedNATGateway" for AKS to select this NAT Gateway.
# ============================================================================

# ---------------------------------------------------------------------------
# Virtual Network
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "this" {
  name                = var.vnet_name
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = var.vnet_address_space

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Subnets
# ---------------------------------------------------------------------------
resource "azurerm_subnet" "aks" {
  name                            = var.aks_subnet_name
  resource_group_name             = var.resource_group_name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.aks_subnet_address_prefix]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "pe" {
  name                            = var.pe_subnet_name
  resource_group_name             = var.resource_group_name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.pe_subnet_address_prefix]
  default_outbound_access_enabled = false

  # AzureRM 4+ uses the string-valued property. Network security group
  # policies must be enabled on the subnet before an NSG can filter traffic
  # to Private Endpoints.
  private_endpoint_network_policies = "NetworkSecurityGroupEnabled"
}

resource "azurerm_subnet" "reserved" {
  name                            = var.reserved_subnet_name
  resource_group_name             = var.resource_group_name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.reserved_subnet_address_prefix]
  default_outbound_access_enabled = false
}

# ---------------------------------------------------------------------------
# NAT Gateway (explicit outbound connectivity for the AKS subnet)
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "nat" {
  name                = var.nat_public_ip_name
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  ip_version          = "IPv4"

  tags = var.tags
}

resource "azurerm_nat_gateway" "this" {
  name                = var.nat_gateway_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = "Standard"

  tags = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "aks" {
  subnet_id      = azurerm_subnet.aks.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

# ---------------------------------------------------------------------------
# Network Security Groups
# ---------------------------------------------------------------------------

# AKS subnet NSG.
#
# Deliberately leave custom security rules out of this NSG. Azure NSGs include
# default rules that allow VirtualNetwork and AzureLoadBalancer inbound traffic
# and deny other inbound traffic. Adding a subnet-level deny rule can also
# break AKS networking models such as Azure CNI Overlay because the required
# pod/node traffic depends on the actual pod CIDR and cluster configuration.
resource "azurerm_network_security_group" "aks" {
  name                = var.aks_nsg_name
  location            = var.location
  resource_group_name = var.resource_group_name

  tags = var.tags
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

# Private endpoint subnet NSG.
# Only the AKS subnet is allowed to initiate PostgreSQL connections to the
# private endpoint. Azure NSGs are stateful, so response traffic is allowed.
resource "azurerm_network_security_group" "pe" {
  name                = var.pe_nsg_name
  location            = var.location
  resource_group_name = var.resource_group_name

  security_rule {
    name                       = "AllowPostgreSQLFromAks"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = var.aks_subnet_address_prefix
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = var.tags
}

resource "azurerm_subnet_network_security_group_association" "pe" {
  subnet_id                 = azurerm_subnet.pe.id
  network_security_group_id = azurerm_network_security_group.pe.id
}

# ---------------------------------------------------------------------------
# PostgreSQL Private DNS
# ---------------------------------------------------------------------------
resource "azurerm_private_dns_zone" "postgres" {
  name                = var.private_dns_zone_name
  resource_group_name = var.resource_group_name

  tags = var.tags
}

# AzureRM 5.x requires the DNS zone resource ID rather than the old
# private_dns_zone_name + resource_group_name argument pair.
resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                 = var.private_dns_zone_link_name
  private_dns_zone_id  = azurerm_private_dns_zone.postgres.id
  virtual_network_id   = azurerm_virtual_network.this.id
  registration_enabled = false
}
