variable "tfstate_subscription_id" {
  description = "Subscription ID for the remote state backend."
  type        = string
}

variable "tfstate_tenant_id" {
  description = "Tenant ID for the remote state backend."
  type        = string
}

variable "tfstate_client_id" {
  description = "Client ID (service principal) for the remote state backend."
  type        = string
}

# ---- Azure DevOps project & service connections (created by bootstrap) ----
variable "project_name" {
  description = "Azure DevOps project name."
  type        = string
}

variable "github_service_connection_name" {
  description = "Name of the GitHub service connection."
  type        = string
}

variable "azure_service_connection_name" {
  description = "Name of the Azure service connection (e.g. azdo-oidc-ci)."
  type        = string
}

variable "github_owner" {
  description = "GitHub repository owner."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name."
  type        = string
}

variable "branch" {
  description = "Default branch for the pipeline."
  type        = string
  default     = "main"
}

# ---- Terraform remote state access (for variable groups) ----
variable "tfstate_resource_group_name" {
  description = "Resource group of the remote state storage account."
  type        = string
}

variable "tfstate_storage_account_name" {
  description = "Storage account holding the remote state."
  type        = string
}

variable "tfstate_container_name" {
  description = "Container holding the remote state."
  type        = string
}

variable "tfstate_key" {
  description = "State key for the main environment (e.g. main/terraform/staging.tfstate)."
  type        = string
}

variable "storage_account_name" {
  description = "Data lake storage account name."
  type        = string
}

variable "mlflow_tracking_uri" {
  description = "MLflow tracking URI."
  type        = string
}

variable "container_registry_name" {
  description = "ACR name."
  type        = string
}

variable "train_job_name" {
  description = "Training Container App Job name."
  type        = string
}

variable "serve_app_name" {
  description = "Serving Container App name."
  type        = string
}

variable "staging_resource_group" {
  description = "Staging resource group name."
  type        = string
}

variable "prod_resource_group" {
  description = "Production resource group name."
  type        = string
}


variable "key_vault_name" {
  description = "Name of the central Key Vault (used by pipelines to fetch secrets)."
  type        = string
}
