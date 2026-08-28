# ==============================================================================
# modules/aca/main.tf – Container Apps Environment (serverless runtime)
#
# Only the ACA environment is managed by Terraform.
# Container Apps (serving + training job) are created by run.sh via Azure CLI
# after the environment is warm, avoiding ARM provisioning timeouts on
# student subscriptions.
# ==============================================================================

resource "azurerm_container_app_environment" "this" {
  name                       = var.environment_name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  log_analytics_workspace_id = var.log_analytics_workspace_id

  tags = var.tags
}
