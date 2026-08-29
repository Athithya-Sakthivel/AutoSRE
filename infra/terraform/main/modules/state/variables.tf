# ==============================================================================
# state/variables.tf – Input variables for the base state module
# ==============================================================================

variable "resource_group_name" {
  description = "Name of the Azure resource group that will contain all platform resources."
  type        = string
}

variable "location" {
  description = "Azure region where resources will be created."
  type        = string
  default     = "centralindia"
}

variable "acr_name" {
  description = "Globally unique name for the Azure Container Registry."
  type        = string
}

variable "acr_sku" {
  description = "SKU tier for the Azure Container Registry (Basic, Standard, Premium)."
  type        = string
  default     = "Basic"
}

variable "acr_admin_enabled" {
  description = "Enable admin user for ACR? Should be false for security; use workload identity instead."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags to apply to all resources in this module."
  type        = map(string)
  default     = {}
}
