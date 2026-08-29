# ==============================================================================
# azure_devops/pipelines.tf – Application CI/CD pipelines
#
# Creates only the four application pipelines:
#   - ci-backend  – backend CI
#   - ci-frontend – frontend CI
#   - cd-backend  – backend CD
#   - cd-frontend – frontend CD
#
# Terraform pipelines are intentionally NOT created here because bootstrap
# owns them.
#
# Existing bootstrap-owned resources referenced here:
#   - GitHub service connection
#   - Azure Resource Manager service connection
#   - Azure DevOps project
#
# The CD pipeline completion/trigger behavior is expected to be defined in the
# corresponding YAML files using Azure Pipelines pipeline resources.
# ==============================================================================

# ------------------------------------------------------------------------------
# Existing Azure DevOps project
# ------------------------------------------------------------------------------

data "azuredevops_project" "main" {
  name = var.project_name
}

# ------------------------------------------------------------------------------
# Existing GitHub service connection
# ------------------------------------------------------------------------------

data "azuredevops_serviceendpoint_github" "main" {
  project_id            = data.azuredevops_project.main.id
  service_endpoint_name = var.github_service_connection_name
}

# ------------------------------------------------------------------------------
# Existing Azure Resource Manager service connection
#
# Bootstrap is responsible for creating/configuring this endpoint. This module
# only resolves it so the CD pipelines can be authorized to use it.
# ------------------------------------------------------------------------------

data "azuredevops_serviceendpoint_azurerm" "cd" {
  project_id            = data.azuredevops_project.main.id
  service_endpoint_name = var.azure_service_connection_name
}

# ==============================================================================
# CI PIPELINES
# ==============================================================================

resource "azuredevops_build_definition" "ci_backend" {
  project_id = data.azuredevops_project.main.id
  name       = "${var.github_repo}-ci-backend"
  path       = "\\"

  # The YAML file owns the CI trigger definition.
  ci_trigger {
    use_yaml = true
  }

  # Prevent provisioning from unexpectedly queueing an application run.
  features {
    skip_first_run = true
  }

  repository {
    repo_type             = "GitHub"
    repo_id               = "${var.github_owner}/${var.github_repo}"
    branch_name           = var.branch
    yml_path              = "azure-pipelines/ci/ci-backend.yaml"
    service_connection_id = data.azuredevops_serviceendpoint_github.main.id
    report_build_status   = true
  }

  timeouts {
    create = "30m"
    read   = "5m"
    update = "30m"
    delete = "30m"
  }
}

resource "azuredevops_pipeline_authorization" "ci_backend_github" {
  project_id  = data.azuredevops_project.main.id
  resource_id = data.azuredevops_serviceendpoint_github.main.id
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.ci_backend.id
}

resource "azuredevops_build_definition" "ci_frontend" {
  project_id = data.azuredevops_project.main.id
  name       = "${var.github_repo}-ci-frontend"
  path       = "\\"

  # The YAML file owns the CI trigger definition.
  ci_trigger {
    use_yaml = true
  }

  # Prevent provisioning from unexpectedly queueing an application run.
  features {
    skip_first_run = true
  }

  repository {
    repo_type             = "GitHub"
    repo_id               = "${var.github_owner}/${var.github_repo}"
    branch_name           = var.branch
    yml_path              = "azure-pipelines/ci/ci-frontend.yaml"
    service_connection_id = data.azuredevops_serviceendpoint_github.main.id
    report_build_status   = true
  }

  timeouts {
    create = "30m"
    read   = "5m"
    update = "30m"
    delete = "30m"
  }
}

resource "azuredevops_pipeline_authorization" "ci_frontend_github" {
  project_id  = data.azuredevops_project.main.id
  resource_id = data.azuredevops_serviceendpoint_github.main.id
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.ci_frontend.id
}

# ==============================================================================
# CD PIPELINES
# ==============================================================================

resource "azuredevops_build_definition" "cd_backend" {
  project_id = data.azuredevops_project.main.id
  name       = "${var.github_repo}-cd-backend"
  path       = "\\"

  # Trigger behavior for this YAML pipeline is intentionally delegated to the
  # YAML file. For a completion-trigger-only CD pipeline, that YAML should use:
  #
  #   trigger: none
  #
  # and define the upstream CI pipeline under:
  #
  #   resources:
  #     pipelines:
  #
  # with the appropriate pipeline resource trigger.

  features {
    skip_first_run = true
  }

  repository {
    repo_type             = "GitHub"
    repo_id               = "${var.github_owner}/${var.github_repo}"
    branch_name           = var.branch
    yml_path              = "azure-pipelines/cd/cd-backend.yaml"
    service_connection_id = data.azuredevops_serviceendpoint_github.main.id
    report_build_status   = true
  }

  timeouts {
    create = "30m"
    read   = "5m"
    update = "30m"
    delete = "30m"
  }
}

resource "azuredevops_pipeline_authorization" "cd_backend_github" {
  project_id  = data.azuredevops_project.main.id
  resource_id = data.azuredevops_serviceendpoint_github.main.id
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.cd_backend.id
}

resource "azuredevops_pipeline_authorization" "cd_backend_azure" {
  project_id  = data.azuredevops_project.main.id
  resource_id = data.azuredevops_serviceendpoint_azurerm.cd.id
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.cd_backend.id
}

resource "azuredevops_build_definition" "cd_frontend" {
  project_id = data.azuredevops_project.main.id
  name       = "${var.github_repo}-cd-frontend"
  path       = "\\"

  # Trigger behavior for this YAML pipeline is intentionally delegated to the
  # YAML file. For a completion-trigger-only CD pipeline, that YAML should use:
  #
  #   trigger: none
  #
  # and define the upstream CI pipeline under:
  #
  #   resources:
  #     pipelines:
  #
  # with the appropriate pipeline resource trigger.

  features {
    skip_first_run = true
  }

  repository {
    repo_type             = "GitHub"
    repo_id               = "${var.github_owner}/${var.github_repo}"
    branch_name           = var.branch
    yml_path              = "azure-pipelines/cd/cd-frontend.yaml"
    service_connection_id = data.azuredevops_serviceendpoint_github.main.id
    report_build_status   = true
  }

  timeouts {
    create = "30m"
    read   = "5m"
    update = "30m"
    delete = "30m"
  }
}

resource "azuredevops_pipeline_authorization" "cd_frontend_github" {
  project_id  = data.azuredevops_project.main.id
  resource_id = data.azuredevops_serviceendpoint_github.main.id
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.cd_frontend.id
}

resource "azuredevops_pipeline_authorization" "cd_frontend_azure" {
  project_id  = data.azuredevops_project.main.id
  resource_id = data.azuredevops_serviceendpoint_azurerm.cd.id
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.cd_frontend.id
}
