output "workspace_name" {
  description = "Azure Machine Learning workspace name."
  value       = azurerm_machine_learning_workspace.this.name
}

output "workspace_id" {
  description = "Azure Machine Learning workspace resource ID."
  value       = azurerm_machine_learning_workspace.this.id
}

output "mlflow_tracking_uri" {
  description = "MLflow tracking URI for the workspace."
  value       = "azureml://${var.location}.api.azureml.ms/mlflow/v1.0/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.MachineLearningServices/workspaces/${azurerm_machine_learning_workspace.this.name}"
}

output "ml_storage_account_name" {
  description = "Name of the dedicated AML storage account."
  value       = azurerm_storage_account.ml.name
}

output "ml_storage_account_id" {
  description = "Resource ID of the dedicated AML storage account."
  value       = azurerm_storage_account.ml.id
}

# Note: Key Vault outputs are no longer emitted from this module.
# Use the central `key_vault` module outputs instead.
