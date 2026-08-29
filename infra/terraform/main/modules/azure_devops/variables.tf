# ==============================================================================
# azure_devops/variables.tf – Input variables
# ==============================================================================

variable "project_name" {
  description = "Azure DevOps project name created during bootstrap."
  type        = string

  validation {
    condition     = length(trimspace(var.project_name)) > 0
    error_message = "project_name must not be empty."
  }
}

variable "github_service_connection_name" {
  description = "Name of the existing GitHub service connection created during bootstrap."
  type        = string
  default     = "github-pat"

  validation {
    condition     = length(trimspace(var.github_service_connection_name)) > 0
    error_message = "github_service_connection_name must not be empty."
  }
}

variable "azure_service_connection_name" {
  description = "Name of the existing Azure Resource Manager service connection used for CD pipelines. The service connection is expected to use workload identity federation (OIDC)."
  type        = string
  default     = "azdo-oidc-cd"

  validation {
    condition     = length(trimspace(var.azure_service_connection_name)) > 0
    error_message = "azure_service_connection_name must not be empty."
  }
}

variable "github_owner" {
  description = "GitHub repository owner (organization or user)."
  type        = string

  validation {
    condition     = length(trimspace(var.github_owner)) > 0
    error_message = "github_owner must not be empty."
  }
}

variable "github_repo" {
  description = "GitHub repository name."
  type        = string

  validation {
    condition     = length(trimspace(var.github_repo)) > 0
    error_message = "github_repo must not be empty."
  }
}

variable "branch" {
  description = "Default GitHub branch used by the Azure DevOps pipeline definitions."
  type        = string
  default     = "main"

  validation {
    condition     = length(trimspace(var.branch)) > 0
    error_message = "branch must not be empty."
  }
}

variable "terraform_vars_group_name" {
  description = "Name of the existing Azure DevOps variable group created by bootstrap."
  type        = string
  default     = "terraform-vars"

  validation {
    condition     = length(trimspace(var.terraform_vars_group_name)) > 0
    error_message = "terraform_vars_group_name must not be empty."
  }
}

variable "authorize_variable_group_for_ci" {
  description = "Whether the existing terraform-vars variable group should also be authorized for the application CI pipelines. Keep false unless the CI YAML files explicitly consume this variable group."
  type        = bool
  default     = false
}
