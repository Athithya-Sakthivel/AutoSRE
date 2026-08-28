# ==============================================================================
# pipelines.tf – Application‑level CI/CD pipelines in Azure DevOps
#
# Declares the five pipelines that validate and deploy the ML workloads:
#   • ci-elt
#   • ci-ml-training
#   • ci-service
#   • cd-training-job
#   • cd-service
#
# All pipelines reference YAML definitions in the /azure-pipelines directory.
# The Azure DevOps project and GitHub service connection already exist
# (created by the bootstrap stage), so they are read via data sources.
# ==============================================================================

# ------------------------------------------------------------------------------
# Data lookups – project, GitHub service connection, production environment
# ------------------------------------------------------------------------------
data "azuredevops_project" "main" {
  name = var.project_name
}

data "azuredevops_serviceendpoint_github" "main" {
  project_id            = data.azuredevops_project.main.id
  service_endpoint_name = var.github_service_connection_name
}

data "azuredevops_environment" "production" {
  project_id = data.azuredevops_project.main.id
  name       = "production"
}

# ==============================================================================
# CI pipelines
# ==============================================================================

# ------------------------------------------------------------------------------
# ELT CI – triggered on changes to data extraction/transformation code
# ------------------------------------------------------------------------------
resource "azuredevops_build_definition" "elt_ci" {
  project_id = data.azuredevops_project.main.id
  name       = "${var.github_repo}-elt-ci"
  path       = "\\"

  ci_trigger {
    use_yaml = true
  }

  repository {
    repo_type             = "GitHub"
    repo_id               = "${var.github_owner}/${var.github_repo}"
    branch_name           = var.branch
    yml_path              = "azure-pipelines/ci/ci-elt.yaml"
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

resource "azuredevops_pipeline_authorization" "elt_ci_github" {
  project_id  = data.azuredevops_project.main.id
  resource_id = data.azuredevops_serviceendpoint_github.main.id
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.elt_ci.id
}

# ------------------------------------------------------------------------------
# ML Training CI – triggered on changes to model training code
# ------------------------------------------------------------------------------
resource "azuredevops_build_definition" "ml_training_ci" {
  project_id = data.azuredevops_project.main.id
  name       = "${var.github_repo}-ml-training-ci"
  path       = "\\"

  ci_trigger {
    use_yaml = true
  }

  repository {
    repo_type             = "GitHub"
    repo_id               = "${var.github_owner}/${var.github_repo}"
    branch_name           = var.branch
    yml_path              = "azure-pipelines/ci/ci-ml-training.yaml"
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

resource "azuredevops_pipeline_authorization" "ml_training_ci_github" {
  project_id  = data.azuredevops_project.main.id
  resource_id = data.azuredevops_serviceendpoint_github.main.id
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.ml_training_ci.id
}

# ------------------------------------------------------------------------------
# Serving CI – triggered on changes to serving API code
# ------------------------------------------------------------------------------
resource "azuredevops_build_definition" "service_ci" {
  project_id = data.azuredevops_project.main.id
  name       = "${var.github_repo}-service-ci"
  path       = "\\"

  ci_trigger {
    use_yaml = true
  }

  repository {
    repo_type             = "GitHub"
    repo_id               = "${var.github_owner}/${var.github_repo}"
    branch_name           = var.branch
    yml_path              = "azure-pipelines/ci/ci-service.yaml"
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

resource "azuredevops_pipeline_authorization" "service_ci_github" {
  project_id  = data.azuredevops_project.main.id
  resource_id = data.azuredevops_serviceendpoint_github.main.id
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.service_ci.id
}

# ==============================================================================
# CD pipelines
# ==============================================================================

# ------------------------------------------------------------------------------
# Training CD – builds training image and updates ACA Job (staging → prod)
# ------------------------------------------------------------------------------
resource "azuredevops_build_definition" "training_cd" {
  project_id = data.azuredevops_project.main.id
  name       = "${var.github_repo}-train-cd"
  path       = "\\"

  ci_trigger {
    use_yaml = true
  }

  repository {
    repo_type             = "GitHub"
    repo_id               = "${var.github_owner}/${var.github_repo}"
    branch_name           = var.branch
    yml_path              = "azure-pipelines/cd/cd-training-job.yaml"
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

resource "azuredevops_pipeline_authorization" "training_cd_github" {
  project_id  = data.azuredevops_project.main.id
  resource_id = data.azuredevops_serviceendpoint_github.main.id
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.training_cd.id
}

resource "azuredevops_pipeline_authorization" "training_cd_production_env" {
  project_id  = data.azuredevops_project.main.id
  resource_id = data.azuredevops_environment.production.id
  type        = "environment"
  pipeline_id = azuredevops_build_definition.training_cd.id
}

# ------------------------------------------------------------------------------
# Serving CD – canary deployment of the serving API (staging → prod)
# ------------------------------------------------------------------------------
resource "azuredevops_build_definition" "service_cd" {
  project_id = data.azuredevops_project.main.id
  name       = "${var.github_repo}-serve-cd"
  path       = "\\"

  ci_trigger {
    use_yaml = true
  }

  repository {
    repo_type             = "GitHub"
    repo_id               = "${var.github_owner}/${var.github_repo}"
    branch_name           = var.branch
    yml_path              = "azure-pipelines/cd/cd-service.yaml"
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

resource "azuredevops_pipeline_authorization" "service_cd_github" {
  project_id  = data.azuredevops_project.main.id
  resource_id = data.azuredevops_serviceendpoint_github.main.id
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.service_cd.id
}

resource "azuredevops_pipeline_authorization" "service_cd_production_env" {
  project_id  = data.azuredevops_project.main.id
  resource_id = data.azuredevops_environment.production.id
  type        = "environment"
  pipeline_id = azuredevops_build_definition.service_cd.id
}

resource "azuredevops_pipeline_authorization" "train_cd_variable_group" {
  project_id  = data.azuredevops_project.main.id
  resource_id = azuredevops_variable_group.sm_all_vars.id
  type        = "variablegroup"
  pipeline_id = azuredevops_build_definition.training_cd.id
}
