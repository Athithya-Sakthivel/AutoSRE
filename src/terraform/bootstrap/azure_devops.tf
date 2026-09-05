# ------------------------------------------------------------------------------
# Azure DevOps CI/CD surface: pipelines, environment, and authorizations.
# Variable groups were removed; AzureCLI@2 + service connections provide auth.
# ------------------------------------------------------------------------------

locals {
  github_repo_id = "${var.github_owner}/${var.github_repo}"

  pipelines = {
    security_scan = {
      name      = "${var.github_repo}-full-repo-security-scan"
      yaml_path = "azure-pipelines/ci/full_repo_security_scan.yaml"
    }
    terraform_ci = {
      name      = "${var.github_repo}-terraform-ci"
      yaml_path = "azure-pipelines/ci/ci-terraform.yaml"
    }
    terraform_cd = {
      name      = "${var.github_repo}-terraform-cd"
      yaml_path = "azure-pipelines/cd/cd-terraform.yaml"
    }
  }
}

# ------------------------------------------------------------------------------
# Pipeline definitions
# ------------------------------------------------------------------------------

resource "azuredevops_build_definition" "pipeline" {
  for_each   = local.pipelines
  project_id = azuredevops_project.this.id
  name       = each.value.name
  path       = "\\"

  ci_trigger {
    use_yaml = true
  }

  repository {
    repo_type             = "GitHub"
    repo_id               = local.github_repo_id
    branch_name           = "main"
    yml_path              = each.value.yaml_path
    service_connection_id = azuredevops_serviceendpoint_github.this.id
    report_build_status    = true
  }

  timeouts {
    create = "30m"
    read   = "5m"
    update = "30m"
    delete = "30m"
  }
}

# ------------------------------------------------------------------------------
# Production environment
# ------------------------------------------------------------------------------

resource "azuredevops_environment" "production" {
  project_id   = azuredevops_project.this.id
  name         = "production"
  description  = "Production environment for Terraform CD approval"
}

# ------------------------------------------------------------------------------
# Pipeline authorizations
# ------------------------------------------------------------------------------

resource "azuredevops_pipeline_authorization" "github_endpoint_security_scan" {
  project_id  = azuredevops_project.this.id
  resource_id = azuredevops_serviceendpoint_github.this.id
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.pipeline["security_scan"].id
}

resource "azuredevops_pipeline_authorization" "github_endpoint_terraform_ci" {
  project_id  = azuredevops_project.this.id
  resource_id = azuredevops_serviceendpoint_github.this.id
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.pipeline["terraform_ci"].id
}

resource "azuredevops_pipeline_authorization" "github_endpoint_terraform_cd" {
  project_id  = azuredevops_project.this.id
  resource_id = azuredevops_serviceendpoint_github.this.id
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.pipeline["terraform_cd"].id
}

resource "azuredevops_pipeline_authorization" "terraform_ci_azure_endpoint" {
  project_id  = azuredevops_project.this.id
  resource_id = azuredevops_serviceendpoint_azurerm.ci.id
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.pipeline["terraform_ci"].id
}

resource "azuredevops_pipeline_authorization" "terraform_cd_azure_endpoint" {
  project_id  = azuredevops_project.this.id
  resource_id = azuredevops_serviceendpoint_azurerm.cd.id
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.pipeline["terraform_cd"].id
}

resource "azuredevops_pipeline_authorization" "terraform_cd_environment" {
  project_id  = azuredevops_project.this.id
  resource_id = azuredevops_environment.production.id
  type        = "environment"
  pipeline_id = azuredevops_build_definition.pipeline["terraform_cd"].id
}