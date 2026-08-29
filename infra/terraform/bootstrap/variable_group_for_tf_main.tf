# ------------------------------------------------------------------------------
# Variable group for terraform-ci / terraform-cd pipelines.
# Holds non-derivable Terraform variables *and* the credentials that the
# Azure DevOps provider inside src/terraform/main needs at runtime.
# ------------------------------------------------------------------------------

resource "azuredevops_variable_group" "terraform_vars" {
  project_id   = azuredevops_project.this.id
  name         = "terraform-vars"
  description  = "Common Terraform variables and Azure DevOps credentials for CI/CD pipelines"
  allow_access = true

  variable {
  name  = "TF_VAR_owner"
  value = var.owner
  }

  # ---------- Terraform input variables (not derivable) -----------------------
  variable {
    name  = "TF_VAR_location"
    value = var.location
  }

  variable {
    name  = "TF_VAR_alert_email_address"
    value = var.alert_email_address
  }

  variable {
    name  = "TF_VAR_DOMAIN"
    value = var.DOMAIN
  }

  # ---------- Azure DevOps provider credentials (used by main/run.sh) --------------
  variable {
    name  = "AZDO_ORG_SERVICE_URL"
    value = var.AZDO_ORG_SERVICE_URL
  }

  # ---------- Non-sensitive infrastructure values -------------------------------
  variable {
    name  = "TF_VAR_cloudflare_tunnel_name"
    value = var.cloudflare_tunnel_name
  }

  variable {
    name  = "TF_VAR_cloudflare_tunnel_id"
    value = var.cloudflare_tunnel_id
  }

}
