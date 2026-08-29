# ==============================================================================
# azure_devops/variable_group.tf – Existing variable group authorization
#
# Bootstrap owns creation of the terraform-vars variable group.
# This module only:
#   1. Looks it up.
#   2. Authorizes the CD pipelines to consume it.
#   3. Optionally authorizes the CI pipelines when explicitly enabled.
# ==============================================================================

data "azuredevops_variable_group" "terraform_vars" {
  project_id = data.azuredevops_project.main.id
  name       = var.terraform_vars_group_name
}

# ------------------------------------------------------------------------------
# CD pipeline access
# ------------------------------------------------------------------------------

resource "azuredevops_pipeline_authorization" "cd_backend_variable_group" {
  project_id  = data.azuredevops_project.main.id
  resource_id = data.azuredevops_variable_group.terraform_vars.id
  type        = "variablegroup"
  pipeline_id = azuredevops_build_definition.cd_backend.id
}

resource "azuredevops_pipeline_authorization" "cd_frontend_variable_group" {
  project_id  = data.azuredevops_project.main.id
  resource_id = data.azuredevops_variable_group.terraform_vars.id
  type        = "variablegroup"
  pipeline_id = azuredevops_build_definition.cd_frontend.id
}

# ------------------------------------------------------------------------------
# Optional CI pipeline access
#
# Disabled by default so a secret-bearing variable group is not unnecessarily
# exposed to CI pipelines.
# ------------------------------------------------------------------------------

resource "azuredevops_pipeline_authorization" "ci_backend_variable_group" {
  count = var.authorize_variable_group_for_ci ? 1 : 0

  project_id  = data.azuredevops_project.main.id
  resource_id = data.azuredevops_variable_group.terraform_vars.id
  type        = "variablegroup"
  pipeline_id = azuredevops_build_definition.ci_backend.id
}

resource "azuredevops_pipeline_authorization" "ci_frontend_variable_group" {
  count = var.authorize_variable_group_for_ci ? 1 : 0

  project_id  = data.azuredevops_project.main.id
  resource_id = data.azuredevops_variable_group.terraform_vars.id
  type        = "variablegroup"
  pipeline_id = azuredevops_build_definition.ci_frontend.id
}
