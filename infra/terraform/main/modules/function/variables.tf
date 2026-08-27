variable "resource_group_name" {
  type        = string
  description = "Resource group that will host the Function App."
}

variable "location" {
  type        = string
  description = "Azure region for the Function App resources."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all resources in this module."
}

variable "function_app_name" {
  type        = string
  description = "Name of the Azure Function App."
}

variable "service_plan_name" {
  type        = string
  description = "Name of the Flex Consumption service plan."
}

variable "storage_account_name" {
  type        = string
  description = "Name of the Function App runtime/deployment storage account."
}

variable "deployment_container_name" {
  type        = string
  default     = "deploymentpackage"
  description = "Blob container used for Flex Consumption code deployments."
}

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID used by the Function to start the ACA Job."
}

variable "aca_resource_group_name" {
  type        = string
  description = "Resource group containing the Container Apps Job."
}

variable "aca_job_name" {
  type        = string
  description = "Container Apps Job name to start."
}

variable "aca_job_id" {
  type        = string
  description = "Full resource ID of the Container Apps Job."
}

variable "aca_job_api_version" {
  type        = string
  default     = "2026-01-01"
  description = "Azure Container Apps Jobs API version for the start call."
}

variable "aca_request_timeout_seconds" {
  type        = number
  default     = 30
  description = "Timeout for the ARM start call."
}

variable "source_storage_account_id" {
  type        = string
  description = "Resource ID of the source artifact storage account."
}

variable "source_storage_account_name" {
  type        = string
  description = "Name of the source artifact storage account."
}

variable "source_storage_account_blob_endpoint" {
  type        = string
  description = "Blob endpoint of the source artifact storage account."
}

variable "application_insights_connection_string" {
  type        = string
  sensitive   = true
  description = "Application Insights connection string for telemetry."
}

variable "runtime_name" {
  type        = string
  default     = "python"
  description = "Azure Functions runtime name."
}

variable "runtime_version" {
  type        = string
  default     = "3.13" # Latest compatible as of today
  description = "Azure Functions runtime version."
}

variable "maximum_instance_count" {
  type        = number
  default     = 10
  description = "Maximum instance count for the Flex Consumption plan."
}

variable "instance_memory_in_mb" {
  type        = number
  default     = 2048
  description = "Memory per instance for the Flex Consumption plan."
}