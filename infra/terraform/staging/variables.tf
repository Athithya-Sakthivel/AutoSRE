variable "subscription_id" {
  type     = string
  nullable = false

  validation {
    condition = can(regex(
      "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
      var.subscription_id
    ))
    error_message = "subscription_id must be a valid UUID."
  }
}

variable "tenant_id" {
  type     = string
  nullable = false

  validation {
    condition = can(regex(
      "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
      var.tenant_id
    ))
    error_message = "tenant_id must be a valid UUID."
  }
}

variable "location" {
  type     = string
  nullable = false

  validation {
    condition     = length(trimspace(var.location)) > 0
    error_message = "location must not be empty."
  }
}

variable "resource_group_name" {
  type     = string
  nullable = false

  validation {
    condition     = length(trimspace(var.resource_group_name)) >= 1
    error_message = "resource_group_name must not be empty."
  }
}

variable "key_vault_name" {
  type     = string
  nullable = false

  validation {
    condition = (
      length(var.key_vault_name) >= 3 &&
      length(var.key_vault_name) <= 24 &&
      can(regex("^[a-zA-Z][a-zA-Z0-9-]+$", var.key_vault_name))
    )
    error_message = "key_vault_name must be 3-24 characters, start with a letter, and contain only letters, digits, and hyphens."
  }
}
