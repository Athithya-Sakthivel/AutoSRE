# ==============================================================================
# modules/postgresql/variables.tf
# Input variables for the PostgreSQL Flexible Server module.
# ==============================================================================

variable "resource_group_name" {
  description = "Name of the resource group where the PostgreSQL Flexible Server will be created."
  type        = string

  validation {
    condition     = length(trimspace(var.resource_group_name)) > 0
    error_message = "resource_group_name must not be empty."
  }
}

variable "location" {
  description = "Azure region for the PostgreSQL Flexible Server."
  type        = string
  default     = "centralindia"

  validation {
    condition     = length(trimspace(var.location)) > 0
    error_message = "location must not be empty."
  }
}

variable "server_name" {
  description = "Globally unique name for the PostgreSQL Flexible Server."
  type        = string

  validation {
    condition = can(
      regex(
        "^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])?$",
        var.server_name
      )
    )
    error_message = "server_name must be 3-63 characters, use only lowercase letters, numbers, and hyphens, and not start or end with a hyphen."
  }
}

variable "postgresql_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "18"

  validation {
    condition     = contains(["16", "17", "18"], var.postgresql_version)
    error_message = "postgresql_version must be 16, 17, or 18."
  }
}

variable "sku_name" {
  description = "Azure PostgreSQL Flexible Server SKU."
  type        = string
  default     = "B_Standard_B1ms"

  validation {
    condition     = var.sku_name == "B_Standard_B1ms"
    error_message = "sku_name must be \"B_Standard_B1ms\" for this module's locked design."
  }
}

variable "storage_mb" {
  description = "PostgreSQL Flexible Server storage size in MB."
  type        = number
  default     = 32768

  validation {
    condition = contains(
      [
        32768,
        65536,
        131072,
        262144,
        524288,
        1048576,
        2097152,
        4193280,
        4194304,
        8388608,
        16777216,
        33553408
      ],
      var.storage_mb
    )
    error_message = "storage_mb must be one of the Azure-supported PostgreSQL Flexible Server storage sizes."
  }
}

variable "backup_retention_days" {
  description = "Number of days to retain automated backups. Azure permits 7-35 days."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 7 and 35."
  }
}

variable "administrator_login" {
  description = "Administrator username for the PostgreSQL Flexible Server."
  type        = string
  default     = "taskuser"

  validation {
    condition     = length(trimspace(var.administrator_login)) > 0
    error_message = "administrator_login must not be empty."
  }
}

variable "administrator_password" {
  description = <<-EOT
    Administrator password for the PostgreSQL Flexible Server.

    This variable is ephemeral so OpenTofu does not persist the value in module
    state. The resource receives it through AzureRM's write-only
    administrator_password_wo argument.
  EOT

  type      = string
  sensitive = true
  ephemeral = true

  validation {
    condition = (
      length(var.administrator_password) >= 8 &&
      length(var.administrator_password) <= 128
    )
    error_message = "administrator_password must be between 8 and 128 characters."
  }
}

variable "administrator_password_version" {
  description = <<-EOT
    Non-secret version number used to trigger a PostgreSQL administrator
    password update when the Key Vault secret is rotated.

    Increment this value whenever the referenced Key Vault password changes.
  EOT

  type    = number
  default = 1

  validation {
    condition     = var.administrator_password_version >= 1
    error_message = "administrator_password_version must be at least 1."
  }
}

variable "database_name" {
  description = "Name of the database to create."
  type        = string
  default     = "taskdb"

  validation {
    condition = can(
      regex(
        "^[a-zA-Z_][a-zA-Z0-9_$]{0,62}$",
        var.database_name
      )
    )
    error_message = "database_name must be a valid PostgreSQL identifier of 1-63 characters."
  }
}

variable "private_endpoint_subnet_id" {
  description = "ID of the subnet where the PostgreSQL private endpoint will be created."
  type        = string

  validation {
    condition = can(
      regex(
        "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Network/virtualNetworks/[^/]+/subnets/[^/]+$",
        var.private_endpoint_subnet_id
      )
    )
    error_message = "private_endpoint_subnet_id must be a valid Azure subnet resource ID."
  }
}

variable "private_dns_zone_id" {
  description = "ID of the Private DNS zone used by the PostgreSQL private endpoint. The zone should be privatelink.postgres.database.azure.com."
  type        = string

  validation {
    condition = can(
      regex(
        "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Network/privateDnsZones/[^/]+$",
        var.private_dns_zone_id
      )
    )
    error_message = "private_dns_zone_id must be a valid Azure Private DNS zone resource ID."
  }
}

variable "tags" {
  description = "Common tags to apply to PostgreSQL resources."
  type        = map(string)
  default     = {}
}
