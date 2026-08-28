variable "resource_group_name" {
  description = "Application resource group name."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "storage_account_name" {
  description = "ADLS Gen2 storage account name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3-24 characters, lowercase letters and digits only."
  }
}

variable "acr_name" {
  description = "Azure Container Registry name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{5,50}$", var.acr_name))
    error_message = "acr_name must be 5-50 characters, lowercase letters and digits only."
  }
}

variable "container_names" {
  description = "Blob containers to create."
  type        = list(string)
  default     = ["raw", "clean", "models", "logs"]
}

variable "shared_access_key_enabled" {
  description = "Enable shared access key authentication. Set false after initial apply."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common resource tags."
  type        = map(string)
  default     = {}
}
