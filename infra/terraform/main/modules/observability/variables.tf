# ============================================================================
# modules/observability/variables.tf
# Inputs for the observability module.
# ============================================================================

variable "resource_group_name" {
  description = "Name of the resource group in which observability resources are created."
  type        = string

  validation {
    condition     = length(trimspace(var.resource_group_name)) > 0
    error_message = "resource_group_name must not be empty."
  }
}

variable "location" {
  description = "Azure region for observability resources."
  type        = string
  default     = "centralindia"

  validation {
    condition     = length(trimspace(var.location)) > 0
    error_message = "location must not be empty."
  }
}

variable "environment" {
  description = "Deployment environment name."
  type        = string

  validation {
    condition     = contains(["staging", "prod"], lower(trimspace(var.environment)))
    error_message = "environment must be either staging or prod."
  }
}

variable "log_analytics_workspace_name" {
  description = "Name of the Log Analytics workspace. Azure permits 4-63 letters, digits, or hyphens, without a leading/trailing hyphen."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{2,61}[A-Za-z0-9]$", var.log_analytics_workspace_name))
    error_message = "log_analytics_workspace_name must be 4-63 characters and contain only letters, digits, and hyphens, with no leading/trailing hyphen."
  }
}

variable "log_analytics_retention_days" {
  description = "Retention period in days for the Log Analytics workspace."
  type        = number
  default     = 30

  validation {
    condition     = var.log_analytics_retention_days >= 30 && var.log_analytics_retention_days <= 730 && floor(var.log_analytics_retention_days) == var.log_analytics_retention_days
    error_message = "log_analytics_retention_days must be an integer between 30 and 730."
  }
}

variable "application_insights_name" {
  description = "Name of the workspace-based Application Insights component."
  type        = string

  validation {
    condition     = length(trimspace(var.application_insights_name)) > 0
    error_message = "application_insights_name must not be empty."
  }
}

variable "alert_email_address" {
  description = "Email address that receives Azure Monitor action-group notifications."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email_address))
    error_message = "alert_email_address must be a valid email address."
  }
}

variable "aks_cluster_id" {
  description = "ARM resource ID of the AKS managed cluster used by the node CPU/memory metric alerts."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.ContainerService/managedClusters/[^/]+$", var.aks_cluster_id))
    error_message = "aks_cluster_id must be an Azure resource ID for Microsoft.ContainerService/managedClusters."
  }
}

variable "postgresql_server_id" {
  description = "ARM resource ID of the Azure Database for PostgreSQL Flexible Server used by the storage alert."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.DBforPostgreSQL/flexibleServers/[^/]+$", var.postgresql_server_id))
    error_message = "postgresql_server_id must be an Azure resource ID for Microsoft.DBforPostgreSQL/flexibleServers."
  }
}

variable "enable_cpu_alert" {
  description = "Enable the AKS node CPU usage metric alert."
  type        = bool
  default     = true
}

variable "enable_memory_alert" {
  description = "Enable the AKS node memory working-set usage metric alert."
  type        = bool
  default     = true
}

variable "enable_pod_restarts_alert" {
  description = "Enable the Log Analytics scheduled query alert for more than five pod restarts in a 15-minute window."
  type        = bool
  default     = true
}

variable "enable_failed_requests_alert" {
  description = "Enable the Application Insights scheduled query alert when failed requests exceed 5 percent in a 15-minute window."
  type        = bool
  default     = false
}

variable "enable_postgres_storage_alert" {
  description = "Enable the PostgreSQL Flexible Server storage-percent metric alert."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common Azure resource tags."
  type        = map(string)
  default     = {}
}
