variable "resource_group_name" {
  description = "Name of the Azure resource group containing the observability resources."
  type        = string

  validation {
    condition     = length(trimspace(var.resource_group_name)) > 0
    error_message = "resource_group_name must not be empty."
  }
}

variable "location" {
  description = "Azure region for the observability resources."
  type        = string
  default     = "centralindia"

  validation {
    condition     = length(trimspace(var.location)) > 0
    error_message = "location must not be empty."
  }
}

variable "environment" {
  description = "Deployment environment."
  type        = string

  validation {
    condition = contains(
      ["staging", "prod"],
      lower(trimspace(var.environment))
    )

    error_message = "environment must be either staging or prod."
  }
}

variable "log_analytics_workspace_name" {
  description = "Name of the Log Analytics workspace."
  type        = string

  validation {
    condition = can(
      regex(
        "^[A-Za-z0-9][A-Za-z0-9-]{2,61}[A-Za-z0-9]$",
        var.log_analytics_workspace_name
      )
    )

    error_message = "log_analytics_workspace_name must be 4-63 characters and contain only letters, digits, and hyphens, without a leading or trailing hyphen."
  }
}

variable "log_analytics_retention_days" {
  description = "Log Analytics retention period in days."
  type        = number
  default     = 30

  validation {
    condition = (
      var.log_analytics_retention_days >= 30 &&
      var.log_analytics_retention_days <= 730 &&
      floor(var.log_analytics_retention_days) == var.log_analytics_retention_days
    )

    error_message = "log_analytics_retention_days must be an integer between 30 and 730."
  }
}

variable "application_insights_name" {
  description = "Name of the Application Insights component."
  type        = string

  validation {
    condition     = length(trimspace(var.application_insights_name)) > 0
    error_message = "application_insights_name must not be empty."
  }
}

variable "alert_email_address" {
  description = "Email address used by the Azure Monitor action group."
  type        = string

  validation {
    condition = can(
      regex(
        "^[^@]+@[^@]+\\.[^@]+$",
        trimspace(var.alert_email_address)
      )
    )

    error_message = "alert_email_address must be a valid email address."
  }
}

variable "application_insights_sampling_percentage" {
  description = "Server-side Application Insights sampling percentage."
  type        = number
  default     = 100

  validation {
    condition = (
      var.application_insights_sampling_percentage > 0 &&
      var.application_insights_sampling_percentage <= 100
    )

    error_message = "application_insights_sampling_percentage must be between 1 and 100."
  }
}

variable "aks_cluster_id" {
  description = "ARM resource ID of the AKS managed cluster."
  type        = string

  validation {
    condition = can(
      regex(
        "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.ContainerService/managedClusters/[^/]+$",
        var.aks_cluster_id
      )
    )

    error_message = "aks_cluster_id must be an Azure managedClusters resource ID."
  }
}

variable "postgresql_server_id" {
  description = "ARM resource ID of the PostgreSQL Flexible Server. May be null when the PostgreSQL storage alert is disabled."
  type        = string
  default     = null

  validation {
    condition = (
      var.postgresql_server_id == null ||
      can(
        regex(
          "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.DBforPostgreSQL/flexibleServers/[^/]+$",
          var.postgresql_server_id
        )
      )
    )

    error_message = "postgresql_server_id must be null or a Microsoft.DBforPostgreSQL/flexibleServers resource ID."
  }
}

variable "enable_cpu_alert" {
  description = "Enable the AKS node CPU metric alert."
  type        = bool
  default     = true
}

variable "enable_memory_alert" {
  description = "Enable the AKS node memory metric alert."
  type        = bool
  default     = true
}

variable "enable_pod_restarts_alert" {
  description = "Enable the pod restart scheduled query alert."
  type        = bool
  default     = true
}

variable "enable_failed_requests_alert" {
  description = "Enable the Application Insights failed request rate alert."
  type        = bool
  default     = true
}

variable "enable_postgres_storage_alert" {
  description = "Enable the PostgreSQL storage percentage metric alert."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to observability resources."
  type        = map(string)
  default     = {}
}