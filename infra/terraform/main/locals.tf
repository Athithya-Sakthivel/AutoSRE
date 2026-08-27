locals {
  project_name = "serverless-mlops"
  project_abbr = "sm"
  env_abbr     = var.environment == "staging" ? "stg" : "prod"

  sub_suffix = substr(var.subscription_id, length(var.subscription_id) - 6, 6)

  common_tags = merge(
    {
      project     = local.project_name
      managed_by  = "opentofu"
      environment = var.environment
    },
    var.tags
  )

  artifact_resource_group_name = "rg-${local.project_abbr}-artifacts-${local.env_abbr}"
  storage_account_name         = "${local.project_abbr}${local.env_abbr}artifacts${local.sub_suffix}"
  acr_name                     = "acr${local.project_abbr}${local.env_abbr}${local.sub_suffix}"
  log_analytics_workspace_name = "law-${local.project_abbr}-${local.env_abbr}"
  application_insights_name    = "appi-${local.project_abbr}-${local.env_abbr}"
  workbook_display_name        = "Serverless MLOps - ${var.environment == "staging" ? "Staging" : "Production"}"
  action_group_name            = "ag-${local.project_abbr}-${local.env_abbr}"
  action_group_short_name      = "${local.project_abbr}${local.env_abbr}"
  ml_workspace_name            = "mlw-${local.project_abbr}-${local.env_abbr}-e3"
  ml_key_vault_name            = "kv-${local.project_abbr}${local.env_abbr}ml${local.sub_suffix}"
  ml_storage_account_name      = "${local.project_abbr}${local.env_abbr}mlsa${local.sub_suffix}"

  aca_environment_name = "acae-${local.project_abbr}-${local.env_abbr}"
  aca_train_job_name   = "acaj-train-${local.env_abbr}"
  aca_serve_app_name   = "aca-serve-${local.env_abbr}"

  staging_resource_group_name = "rg-${local.project_abbr}-artifacts-stg"
  prod_resource_group_name    = "rg-${local.project_abbr}-artifacts-prod"

  bootstrap_key_vault_name = "kv-azdo-bootstrap-${local.sub_suffix}"
  bootstrap_state_rg       = "rg-sm-state-${local.sub_suffix}"

  # ── Function App names ──────────────────────────────────────────────
  function_app_name                  = "func-blob-trigger-${local.env_abbr}"
  service_plan_name                  = "asp-func-${local.env_abbr}"
  function_storage_name              = "stfunc${local.env_abbr}${local.sub_suffix}"
  function_deployment_container_name = "deploymentpackage"
}