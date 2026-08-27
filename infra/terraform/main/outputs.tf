# ==============================================================================
# Root outputs.tf
#
# Outputs from the serving app and training job are intentionally absent.
# Both are created by run.sh via Azure CLI and their FQDNs / IDs are
# available via `az containerapp show` when needed.
# ==============================================================================

output "artifact_resource_group_name" {
  description = "Name of the resource group that holds all application resources."
  value       = module.state.resource_group_name
}

output "artifact_resource_group_id" {
  description = "ARM resource ID of the application resource group."
  value       = module.state.resource_group_id
}

output "storage_account_name" {
  description = "Name of the ADLS Gen2 data lake storage account."
  value       = module.state.storage_account_name
}

output "storage_account_id" {
  description = "ARM resource ID of the data lake storage account."
  value       = module.state.storage_account_id
}

output "storage_account_blob_endpoint" {
  description = "Blob endpoint of the data lake storage account."
  value       = module.state.storage_account_blob_endpoint
}

output "ml_storage_account_name" {
  description = "Name of the Azure ML workspace's dedicated storage account (HNS disabled)."
  value       = module.ml_workspace.ml_storage_account_name
}

output "ml_storage_account_id" {
  description = "ARM resource ID of the Azure ML workspace's dedicated storage account."
  value       = module.ml_workspace.ml_storage_account_id
}

output "acr_name" {
  description = "Name of the Azure Container Registry."
  value       = module.state.acr_name
}

output "acr_id" {
  description = "ARM resource ID of the Azure Container Registry."
  value       = module.state.acr_id
}

output "acr_login_server" {
  description = "Login server URL of the Azure Container Registry."
  value       = module.state.acr_login_server
}

output "log_analytics_workspace_name" {
  description = "Name of the Log Analytics workspace."
  value       = module.observability.log_analytics_workspace_name
}

output "log_analytics_workspace_id" {
  description = "ARM resource ID of the Log Analytics workspace."
  value       = module.observability.log_analytics_workspace_id
}

output "application_insights_name" {
  description = "Name of the Application Insights component."
  value       = module.observability.application_insights_name
}

output "application_insights_id" {
  description = "ARM resource ID of the Application Insights component."
  value       = module.observability.application_insights_id
}

output "application_insights_connection_string" {
  description = "Connection string for Application Insights telemetry."
  value       = module.observability.application_insights_connection_string
  sensitive   = true
}

output "application_insights_instrumentation_key" {
  description = "Instrumentation key for Application Insights."
  value       = module.observability.application_insights_instrumentation_key
  sensitive   = true
}

output "workbook_id" {
  description = "ARM resource ID of the Azure Monitor Workbook."
  value       = module.observability.workbook_id
}

output "workbook_name" {
  description = "Name of the Azure Monitor Workbook."
  value       = module.observability.workbook_name
}

output "action_group_id" {
  description = "ARM resource ID of the Azure Monitor Action Group."
  value       = module.observability.action_group_id
}

output "ml_workspace_name" {
  description = "Name of the Azure Machine Learning workspace."
  value       = module.ml_workspace.workspace_name
}

output "ml_workspace_id" {
  description = "ARM resource ID of the Azure Machine Learning workspace."
  value       = module.ml_workspace.workspace_id
}

output "mlflow_tracking_uri" {
  description = "MLflow tracking URI for the Azure ML workspace."
  value       = module.ml_workspace.mlflow_tracking_uri
}

output "aca_environment_name" {
  description = "Name of the ACA managed environment."
  value       = module.aca.environment_name
}

output "aca_environment_id" {
  description = "ARM resource ID of the ACA managed environment."
  value       = module.aca.environment_id
}

output "function_app_name" {
  description = "Name of the Azure Function App (blob trigger)."
  value       = module.function.function_app_name
}

output "function_app_id" {
  description = "ARM resource ID of the Azure Function App."
  value       = module.function.function_app_id
}

output "function_app_default_hostname" {
  description = "Default hostname of the Azure Function App."
  value       = module.function.function_app_default_hostname
}

output "elt_ci_pipeline_id" {
  description = "Azure DevOps pipeline ID for the ELT CI pipeline."
  value       = module.azure_devops.elt_ci_pipeline_id
}

output "elt_ci_variable_group_id" {
  description = "Azure DevOps variable group ID for sm-all-vars."
  value       = module.azure_devops.sm_all_vars_id
}