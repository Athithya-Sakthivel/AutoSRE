# ---------------------------------------------------------------------------
# Data source – bootstrap Key Vault (created during bootstrap)
# ---------------------------------------------------------------------------
data "azurerm_key_vault" "bootstrap" {
  name                = local.bootstrap_key_vault_name
  resource_group_name = local.bootstrap_state_rg
}

# ---------------------------------------------------------------------------
# State module – resource group, ADLS Gen2 storage, ACR
# ---------------------------------------------------------------------------
module "state" {
  source = "./modules/state"

  resource_group_name       = local.artifact_resource_group_name
  location                  = var.location
  storage_account_name      = local.storage_account_name
  acr_name                  = local.acr_name
  container_names           = var.storage_container_names
  shared_access_key_enabled = var.shared_access_key_enabled
  tags                      = local.common_tags
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------
module "observability" {
  source = "./modules/observability"

  resource_group_name              = module.state.resource_group_name
  location                         = var.location
  environment                      = var.environment
  log_analytics_workspace_name     = local.log_analytics_workspace_name
  application_insights_name        = local.application_insights_name
  workbook_display_name            = local.workbook_display_name
  action_group_name                = local.action_group_name
  action_group_short_name          = local.action_group_short_name
  alert_email_address              = var.alert_email_address
  enable_request_failures_alert    = var.enable_request_failures_alert
  enable_slow_requests_alert       = var.enable_slow_requests_alert
  enable_exceptions_alert          = var.enable_exceptions_alert
  enable_validation_failures_alert = var.enable_validation_failures_alert
  tags                             = local.common_tags
}

# ---------------------------------------------------------------------------
# ML workspace – uses the bootstrap Key Vault
# ---------------------------------------------------------------------------
module "ml_workspace" {
  source = "./modules/ml_workspace"

  resource_group_name         = module.state.resource_group_name
  location                    = var.location
  environment                 = var.environment
  workspace_name              = local.ml_workspace_name
  key_vault_id                = data.azurerm_key_vault.bootstrap.id
  ml_storage_account_name     = local.ml_storage_account_name
  datalake_storage_account_id = module.state.storage_account_id
  container_registry_id       = module.state.acr_id
  application_insights_id     = module.observability.application_insights_id
  subscription_id             = var.subscription_id
  tenant_id                   = var.tenant_id
  tags                        = local.common_tags
}

# ---------------------------------------------------------------------------
# Azure Function – blob trigger that starts the training job
# ---------------------------------------------------------------------------
module "function" {
  source = "./modules/function"

  resource_group_name = module.state.resource_group_name
  location            = var.location
  tags                = local.common_tags

  function_app_name         = local.function_app_name
  service_plan_name         = local.service_plan_name
  storage_account_name      = local.function_storage_name
  deployment_container_name = local.function_deployment_container_name

  subscription_id             = var.subscription_id
  aca_resource_group_name     = module.state.resource_group_name
  aca_job_name                = local.aca_train_job_name
  aca_job_id                  = "/subscriptions/${var.subscription_id}/resourceGroups/${module.state.resource_group_name}/providers/Microsoft.App/jobs/${local.aca_train_job_name}"
  aca_request_timeout_seconds = 30

  source_storage_account_id            = module.state.storage_account_id
  source_storage_account_name          = module.state.storage_account_name
  source_storage_account_blob_endpoint = module.state.storage_account_blob_endpoint

  application_insights_connection_string = module.observability.application_insights_connection_string
}

# ==============================================================================
# Only the ACA environment is wired here.  The serving app and training job
# are created later by run.sh after the environment is fully provisioned.
# This avoids the ARM "Operation expired" timeout that occurs when Terraform
# creates both the environment and the Container Apps in a single plan on
# student subscriptions.
# ==============================================================================

module "aca" {
  source = "./modules/aca"

  resource_group_name        = module.state.resource_group_name
  location                   = var.location
  environment_name           = local.aca_environment_name
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Azure DevOps pipelines & variable groups
# ---------------------------------------------------------------------------
module "azure_devops" {
  source = "./modules/azure_devops"

  project_name                   = var.ado_project_name
  github_service_connection_name = var.ado_github_service_connection_name
  azure_service_connection_name  = var.ado_azure_service_connection_name
  github_owner                   = var.github_owner
  github_repo                    = var.github_repo
  branch                         = "main"

  tfstate_resource_group_name  = var.state_rg_name
  tfstate_storage_account_name = var.state_storage_account_name
  tfstate_container_name       = var.state_container_name
  tfstate_key                  = "main/terraform/${var.environment}.tfstate"
  tfstate_subscription_id      = var.subscription_id
  tfstate_tenant_id            = var.tenant_id
  tfstate_client_id            = var.ado_client_id

  storage_account_name    = module.state.storage_account_name
  mlflow_tracking_uri     = module.ml_workspace.mlflow_tracking_uri
  container_registry_name = module.state.acr_name
  train_job_name          = local.aca_train_job_name
  serve_app_name          = local.aca_serve_app_name
  staging_resource_group  = local.staging_resource_group_name
  prod_resource_group     = local.prod_resource_group_name
  key_vault_name          = local.bootstrap_key_vault_name
}