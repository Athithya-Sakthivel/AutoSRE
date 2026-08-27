variable "resource_group_name" {
  description = "Resource group name for observability resources."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "environment" {
  description = "Environment name, e.g. staging or prod."
  type        = string

  validation {
    condition     = contains(["staging", "prod"], var.environment)
    error_message = "environment must be one of: staging, prod."
  }
}

variable "log_analytics_workspace_name" {
  description = "Log Analytics workspace name."
  type        = string
}

variable "application_insights_name" {
  description = "Application Insights component name."
  type        = string
}

variable "workbook_display_name" {
  description = "Workbook display name."
  type        = string
}

variable "action_group_name" {
  description = "Azure Monitor action group name."
  type        = string
}

variable "action_group_short_name" {
  description = "Azure Monitor action group short name."
  type        = string

  validation {
    condition     = length(var.action_group_short_name) >= 1 && length(var.action_group_short_name) <= 12
    error_message = "action_group_short_name must be between 1 and 12 characters."
  }
}

variable "alert_email_address" {
  description = "Email address used by the action group."
  type        = string
}

variable "tags" {
  description = "Common resource tags."
  type        = map(string)
  default     = {}
}

variable "enable_request_failures_alert" {
  description = "Toggle for request-failures alert rule."
  type        = bool
  default     = false
}

variable "enable_slow_requests_alert" {
  description = "Toggle for slow-requests alert rule."
  type        = bool
  default     = false
}

variable "enable_exceptions_alert" {
  description = "Toggle for exceptions alert rule."
  type        = bool
  default     = false
}

variable "enable_validation_failures_alert" {
  description = "Toggle for validation-failures alert rule."
  type        = bool
  default     = false
}