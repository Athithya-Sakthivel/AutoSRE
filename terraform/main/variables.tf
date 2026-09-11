# ------------------------------------------------------------------------------
# Core – used by the state module and resource group
# ------------------------------------------------------------------------------
variable "resource_group_name" {
  description = "Name of the resource group for main infrastructure"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "centralindia"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------------------
# Cosmos DB
# ------------------------------------------------------------------------------
variable "cosmosdb_account_name" {
  description = "Globally unique Cosmos DB account name"
  type        = string
}

variable "cosmosdb_offer_type" {
  description = "Offer type: 'Serverless' or 'Standard'"
  type        = string
  default     = "Serverless"
}

variable "cosmosdb_enable_free_tier" {
  description = "Enable free tier discount"
  type        = bool
  default     = false
}

variable "cosmosdb_throughput" {
  description = "Provisioned throughput (RU/s) per container (if Standard)"
  type        = number
  default     = 400
}

# Optional – if you want to use autoscale, you can add:
# variable "cosmosdb_autoscale_max_throughput" { ... }

# ------------------------------------------------------------------------------
# ACR
# ------------------------------------------------------------------------------
variable "acr_name" {
  description = "Globally unique Azure Container Registry name"
  type        = string
}

variable "acr_sku" {
  description = "SKU for ACR: Basic, Standard, or Premium"
  type        = string
  default     = "Basic"
}