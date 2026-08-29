# ==============================================================================
# azure_devops/outputs.tf – Outputs for the Azure DevOps module
# ==============================================================================

output "ci_backend_pipeline_id" {
  description = "ID of the backend CI pipeline."
  value       = azuredevops_build_definition.ci_backend.id
}

output "ci_frontend_pipeline_id" {
  description = "ID of the frontend CI pipeline."
  value       = azuredevops_build_definition.ci_frontend.id
}

output "cd_backend_pipeline_id" {
  description = "ID of the backend CD pipeline."
  value       = azuredevops_build_definition.cd_backend.id
}

output "cd_frontend_pipeline_id" {
  description = "ID of the frontend CD pipeline."
  value       = azuredevops_build_definition.cd_frontend.id
}

output "terraform_vars_group_id" {
  description = "ID of the existing terraform-vars variable group referenced by the application pipelines."
  value       = data.azuredevops_variable_group.terraform_vars.id
}
