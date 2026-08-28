output "elt_ci_pipeline_id" {
  description = "ID of the ELT CI pipeline."
  value       = azuredevops_build_definition.elt_ci.id
}

output "sm_all_vars_id" {
  description = "ID of the sm-all-vars variable group."
  value       = azuredevops_variable_group.sm_all_vars.id
}
