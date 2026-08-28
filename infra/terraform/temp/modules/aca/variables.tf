# ==============================================================================
# modules/aca/variables.tf
# ==============================================================================

variable "resource_group_name" {
  description = "Resource group that owns the ACA environment."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "environment_name" {
  description = "Container Apps managed environment name."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for Container Apps environment logging."
  type        = string
}

variable "tags" {
  description = "Common tags applied to the ACA environment."
  type        = map(string)
  default     = {}
}
