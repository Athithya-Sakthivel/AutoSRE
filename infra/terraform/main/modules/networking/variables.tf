
# ============================================================================
# networking/variables.tf - Input variables for the networking module
# ============================================================================

variable "resource_group_name" {
  description = "Name of the resource group where networking resources will be created."
  type        = string

  validation {
    condition     = trimspace(var.resource_group_name) != ""
    error_message = "resource_group_name must not be empty."
  }
}

variable "location" {
  description = "Azure region for networking resources."
  type        = string
  default     = "centralindia"

  validation {
    condition     = trimspace(var.location) != ""
    error_message = "location must not be empty."
  }
}

variable "vnet_name" {
  description = "Name of the virtual network."
  type        = string

  validation {
    condition     = trimspace(var.vnet_name) != ""
    error_message = "vnet_name must not be empty."
  }
}

variable "vnet_address_space" {
  description = "One or more CIDR address spaces for the virtual network."
  type        = list(string)
  default     = ["10.1.0.0/16"]

  validation {
    condition = length(var.vnet_address_space) > 0 && alltrue([
      for cidr in var.vnet_address_space : can(cidrhost(cidr, 0))
    ])
    error_message = "vnet_address_space must contain at least one valid CIDR prefix."
  }
}

variable "aks_subnet_name" {
  description = "Name of the AKS node subnet."
  type        = string
  default     = "snet-aks"
}

variable "aks_subnet_address_prefix" {
  description = "CIDR prefix for the AKS node subnet."
  type        = string
  default     = "10.1.1.0/24"

  validation {
    condition     = can(cidrhost(var.aks_subnet_address_prefix, 0))
    error_message = "aks_subnet_address_prefix must be a valid CIDR prefix."
  }
}

variable "pe_subnet_name" {
  description = "Name of the private endpoint subnet for PostgreSQL."
  type        = string
  default     = "snet-pe"
}

variable "pe_subnet_address_prefix" {
  description = "CIDR prefix for the private endpoint subnet."
  type        = string
  default     = "10.1.2.0/24"

  validation {
    condition     = can(cidrhost(var.pe_subnet_address_prefix, 0))
    error_message = "pe_subnet_address_prefix must be a valid CIDR prefix."
  }
}

variable "reserved_subnet_name" {
  description = "Name of the reserved subnet for future use."
  type        = string
  default     = "snet-reserved"
}

variable "reserved_subnet_address_prefix" {
  description = "CIDR prefix for the reserved subnet."
  type        = string
  default     = "10.1.3.0/24"

  validation {
    condition     = can(cidrhost(var.reserved_subnet_address_prefix, 0))
    error_message = "reserved_subnet_address_prefix must be a valid CIDR prefix."
  }
}

variable "nat_gateway_name" {
  description = "Name of the NAT gateway."
  type        = string

  validation {
    condition     = trimspace(var.nat_gateway_name) != ""
    error_message = "nat_gateway_name must not be empty."
  }
}

variable "nat_public_ip_name" {
  description = "Name of the public IP address used by the NAT gateway."
  type        = string

  validation {
    condition     = trimspace(var.nat_public_ip_name) != ""
    error_message = "nat_public_ip_name must not be empty."
  }
}

variable "aks_nsg_name" {
  description = "Name of the network security group associated with the AKS subnet."
  type        = string
  default     = "nsg-aks"
}

variable "pe_nsg_name" {
  description = "Name of the network security group associated with the private endpoint subnet."
  type        = string
  default     = "nsg-pe"
}

variable "private_dns_zone_name" {
  description = "Private DNS zone name used by PostgreSQL private endpoints."
  type        = string
  default     = "privatelink.postgres.database.azure.com"

  validation {
    condition     = trimspace(var.private_dns_zone_name) != ""
    error_message = "private_dns_zone_name must not be empty."
  }
}

variable "private_dns_zone_link_name" {
  description = "Name of the virtual network link between the PostgreSQL private DNS zone and the VNet."
  type        = string
  default     = "postgres-vnet-link"
}

variable "tags" {
  description = "Common tags to apply to all supported resources."
  type        = map(string)
  default     = {}
}
