# ------------------------------------------------------------------------------
# Shared variables
# ------------------------------------------------------------------------------
variable "resource_group_name" {
  description = "Name of the resource group for all resources."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources."
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------------------
# Cosmos DB variables
# ------------------------------------------------------------------------------
variable "cosmosdb_account_name" {
  description = "Globally unique Cosmos DB account name (3-44 characters, lowercase alphanumerics and hyphens)."
  type        = string
}

variable "cosmosdb_offer_type" {
  description = "Offer type: 'Serverless' (pay-per-request) or 'Standard' (provisioned throughput)."
  type        = string
  default     = "Serverless"
}

variable "cosmosdb_enable_free_tier" {
  description = "Enable free tier discount (first 1000 RU/s and 25 GB free). Applicable only for new accounts."
  type        = bool
  default     = false
}

variable "cosmosdb_throughput" {
  description = "Provisioned throughput (RU/s) for each container when offer_type = 'Standard'. Ignored for Serverless."
  type        = number
  default     = 400
}

variable "cosmosdb_autoscale_max_throughput" {
  description = "Maximum throughput (RU/s) for autoscale when offer_type = 'Standard'. If set, overrides cosmosdb_throughput."
  type        = number
  default     = null
}

variable "database_name" {
  description = "Name of the SQL database inside Cosmos DB."
  type        = string
  default     = "agent_state_db"
}

variable "checkpoint_container_name" {
  description = "Container name for LangGraph checkpoints."
  type        = string
  default     = "checkpoints"
}

variable "rate_limit_container_name" {
  description = "Container name for rate‑limit counters."
  type        = string
  default     = "rate_limits"
}

variable "rate_limit_default_ttl_seconds" {
  description = "Default TTL (seconds) for rate‑limit items. Set to -1 for no default TTL."
  type        = number
  default     = 7200
}

# ------------------------------------------------------------------------------
# ACR variables
# ------------------------------------------------------------------------------
variable "acr_name" {
  description = "Name of the Azure Container Registry (must be globally unique, 5-50 alphanumerics)."
  type        = string
}

variable "acr_sku" {
  description = "SKU for the ACR: Basic, Standard, or Premium."
  type        = string
  default     = "Basic"
}