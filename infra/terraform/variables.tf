# ==============================================================================
# variables.tf — Terraform variables
# ==============================================================================

variable "o2_endpoint" {
  description = "OpenObserve HTTP(S) endpoint"
  type        = string
  default     = "http://localhost:5080"

  validation {
    condition     = can(regex("^https?://[^[:space:]]+$", var.o2_endpoint))
    error_message = "o2_endpoint must be an http:// or https:// URL."
  }
}

variable "o2_email" {
  description = "OpenObserve username/email"
  type        = string
  sensitive   = true
  default     = "admin@autosre.local"
}

variable "o2_password" {
  description = "OpenObserve password"
  type        = string
  sensitive   = true
  default     = "StagingO2RootPass123!"
}

variable "o2_organization" {
  description = "OpenObserve organization identifier"
  type        = string
  default     = "default"

  validation {
    condition     = length(trimspace(var.o2_organization)) > 0
    error_message = "o2_organization must not be empty."
  }
}

variable "agent_webhook_url" {
  description = "URL that OpenObserve POSTs alert notifications to (cluster DNS)"
  type        = string
  default     = "http://autosre-agent.sre.svc.cluster.local:8000/alerts"

  validation {
    condition     = can(regex("^https?://[^[:space:]]+$", var.agent_webhook_url))
    error_message = "agent_webhook_url must be an http:// or https:// URL."
  }
}
