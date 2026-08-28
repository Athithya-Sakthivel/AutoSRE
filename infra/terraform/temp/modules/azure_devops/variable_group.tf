# ------------------------------------------------------------------------------
# Single variable group for all Serverless MLOps CI/CD pipelines.
# No secrets – everything here is safe to store in Azure DevOps.
# ------------------------------------------------------------------------------

resource "azuredevops_variable_group" "sm_all_vars" {
  project_id   = data.azuredevops_project.main.id
  name         = "sm-all-vars"
  description  = "Non‑secret configuration for Serverless MLOps CI/CD"
  allow_access = true

  # ---- Storage & MLflow ---------------------------------------------------
  variable {
    name  = "AZURE_STORAGE_ACCOUNT_NAME"
    value = var.storage_account_name
  }
  variable {
    name  = "MLFLOW_TRACKING_URI"
    value = var.mlflow_tracking_uri
  }
  variable {
    name  = "RAW_CONTAINER_NAME"
    value = "raw"
  }
  variable {
    name  = "CLEAN_CONTAINER_NAME"
    value = "clean"
  }
  variable {
    name  = "CHECKPOINT_CONTAINER_NAME"
    value = "checkpoints"
  }

  # ---- Azure Container Registry -------------------------------------------
  variable {
    name  = "containerRegistry"
    value = var.container_registry_name
  }

  # ---- Container Apps identities ------------------------------------------
  variable {
    name  = "CONTAINER_APP_JOB_NAME"
    value = var.train_job_name
  }
  variable {
    name  = "CONTAINER_APP_NAME"
    value = var.serve_app_name
  }

  # ---- Azure service connection (OIDC) ------------------------------------
  variable {
    name  = "azureServiceConnection"
    value = var.azure_service_connection_name
  }

  # ---- Environment resource groups ----------------------------------------
  variable {
    name  = "STAGING_RG"
    value = var.staging_resource_group
  }
  variable {
    name  = "PROD_RG"
    value = var.prod_resource_group
  }

  # ---- Key Vault (for pipeline secret fetching) ---------------------------
  variable {
    name  = "KEY_VAULT_NAME"
    value = var.key_vault_name
  }
}
