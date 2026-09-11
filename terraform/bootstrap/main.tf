# ------------------------------------------------------------------------------
# Terraform provider and core Azure DevOps resources.
# This file defines the project and the GitHub service connection.
# ------------------------------------------------------------------------------

provider "azuredevops" {
  org_service_url       = trimsuffix(var.AZDO_ORG_SERVICE_URL, "/")
  personal_access_token = var.AZDO_PERSONAL_ACCESS_TOKEN
}

# ------------------------------------------------------------------------------
# Azure DevOps Project
# ------------------------------------------------------------------------------
resource "azuredevops_project" "this" {
  name               = var.project_name
  visibility         = "private"
  version_control    = "Git"
  work_item_template = "Agile"
  description        = "Managed by OpenTofu"

  timeouts {
    create = "20m"
    read   = "5m"
    update = "20m"
    delete = "20m"
  }
}

# ------------------------------------------------------------------------------
# GitHub Service Connection (PAT-based) – used by pipelines that need to clone repos
# ------------------------------------------------------------------------------
resource "azuredevops_serviceendpoint_github" "this" {
  project_id            = azuredevops_project.this.id
  service_endpoint_name = var.service_endpoint_name
  description           = "GitHub PAT connection managed by OpenTofu"

  auth_personal {
    personal_access_token = var.AZDO_GITHUB_SERVICE_CONNECTION_PAT
  }

  timeouts {
    create = "10m"
    read   = "5m"
    update = "10m"
    delete = "10m"
  }
}