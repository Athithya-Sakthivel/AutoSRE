# Ensure the role assignments are created only after the Function App identity is fully provisioned.
# `depends_on` prevents Terraform from reading a stale principal during a recreate.

resource "azurerm_role_assignment" "source_storage_blob_owner" {
  scope                            = var.source_storage_account_id
  role_definition_name             = "Storage Blob Data Owner"
  principal_id                     = azurerm_function_app_flex_consumption.this.identity[0].principal_id
  skip_service_principal_aad_check = true

  depends_on = [azurerm_function_app_flex_consumption.this]
}

resource "azurerm_role_assignment" "source_storage_queue_contributor" {
  scope                            = var.source_storage_account_id
  role_definition_name             = "Storage Queue Data Contributor"
  principal_id                     = azurerm_function_app_flex_consumption.this.identity[0].principal_id
  skip_service_principal_aad_check = true

  depends_on = [azurerm_function_app_flex_consumption.this]
}
