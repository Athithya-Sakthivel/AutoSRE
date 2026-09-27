variable "o2_endpoint" {
  description = "OpenObserve HTTP endpoint (e.g. http://localhost:5080)"
  type        = string

  validation {
    condition     = can(regex("^https?://", var.o2_endpoint))
    error_message = "o2_endpoint must start with http:// or https://"
  }
}

variable "o2_email" {
  description = "OpenObserve root email"
  type        = string
}

variable "o2_password" {
  description = "OpenObserve root password"
  type        = string
  sensitive   = true
}

variable "o2_organization" {
  description = "OpenObserve organization id"
  type        = string
  default     = "default"
}

variable "agent_webhook_url" {
  description = "URL the alerting destination POSTs to"
  type        = string
  default     = "http://autosre-agent.sre.svc.cluster.local:8000/alerts"
}
