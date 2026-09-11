variable "AZDO_ORG_SERVICE_URL" {
  description = "Azure DevOps organization URL, for example https://dev.azure.com/contoso"
  type        = string

  validation {
    condition     = can(regex("^https://dev\\.azure\\.com/[^/]+/?$", var.AZDO_ORG_SERVICE_URL))
    error_message = "AZDO_ORG_SERVICE_URL must look like https://dev.azure.com/<organization>."
  }
}

variable "AZDO_ORGANIZATION_NAME" {
  description = "The name of the Azure DevOps organization (required for OIDC Subject)."
  type        = string
}

variable "AZDO_PERSONAL_ACCESS_TOKEN" {
  description = "Azure DevOps PAT used by the provider."
  type        = string
  sensitive   = true

  validation {
    condition     = length(trimspace(var.AZDO_PERSONAL_ACCESS_TOKEN)) > 0
    error_message = "AZDO_PERSONAL_ACCESS_TOKEN must not be empty."
  }
}

variable "AZDO_GITHUB_SERVICE_CONNECTION_PAT" {
  description = "GitHub PAT used only to create the Azure DevOps GitHub service connection."
  type        = string
  sensitive   = true

  validation {
    condition     = length(trimspace(var.AZDO_GITHUB_SERVICE_CONNECTION_PAT)) > 0
    error_message = "AZDO_GITHUB_SERVICE_CONNECTION_PAT must not be empty."
  }
}

variable "project_name" {
  description = "Deterministic Azure DevOps project name."
  type        = string

  validation {
    condition     = length(trimspace(var.project_name)) > 0
    error_message = "project_name must not be empty."
  }
}

variable "service_endpoint_name" {
  description = "Azure DevOps GitHub service connection name."
  type        = string

  validation {
    condition     = length(trimspace(var.service_endpoint_name)) > 0
    error_message = "service_endpoint_name must not be empty."
  }
}

variable "github_owner" {
  description = "GitHub repository owner or organization."
  type        = string

  validation {
    condition     = length(trimspace(var.github_owner)) > 0 && !can(regex("/", var.github_owner))
    error_message = "github_owner must be a non-empty owner/org name without slashes."
  }
}

variable "github_repo" {
  description = "GitHub repository name."
  type        = string

  validation {
    condition     = length(trimspace(var.github_repo)) > 0 && !can(regex("/", var.github_repo))
    error_message = "github_repo must be a non-empty repository name without slashes."
  }
}