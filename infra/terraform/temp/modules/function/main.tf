# ==============================================================================
# modules/function/main.tf
#
# Flex Consumption Function App with a system-assigned managed identity.
# The Event Grid subscription that delivers blob events to the Function is
# created by run.sh AFTER the Function code is deployed, because the
# blobs_extension system key is only generated once the host has indexed
# the blob trigger.
# ==============================================================================

# ---------------------------------------------------------------------------
# Flex Consumption service plan – scales to zero, per‑execution billing
# ---------------------------------------------------------------------------
resource "azurerm_service_plan" "this" {
  name                = var.service_plan_name
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "FC1"             # Flex Consumption
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Function App – Python runtime, identity‑based blob trigger connection
# ---------------------------------------------------------------------------
resource "azurerm_function_app_flex_consumption" "this" {
  name                = var.function_app_name
  resource_group_name = var.resource_group_name
  location            = var.location
  service_plan_id     = azurerm_service_plan.this.id

  # Deployment package is stored in a blob container created by storage.tf
  storage_container_type      = "blobContainer"
  storage_container_endpoint   = "${azurerm_storage_account.this.primary_blob_endpoint}${azurerm_storage_container.deploymentpackage.name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.this.primary_access_key

  # Python 3.11 – the latest version supported by Flex Consumption
  runtime_name    = var.runtime_name
  runtime_version = var.runtime_version

  # Scale limits – 0 instances when idle, up to 10 under load
  maximum_instance_count = var.maximum_instance_count
  instance_memory_in_mb  = var.instance_memory_in_mb

  # System-assigned managed identity – used to read blobs and start the ACA job
  identity {
    type = "SystemAssigned"
  }

  # Application Insights connection string (placed in site_config, not app_settings)
  site_config {
    application_insights_connection_string = var.application_insights_connection_string
  }

  # Application settings – available as environment variables at runtime
  app_settings = {
    ACA_SUBSCRIPTION_ID          = var.subscription_id
    ACA_RESOURCE_GROUP_NAME      = var.resource_group_name
    ACA_JOB_NAME                 = var.aca_job_name
    ACA_JOB_API_VERSION          = var.aca_job_api_version
    ACA_REQUEST_TIMEOUT_SECONDS  = tostring(var.aca_request_timeout_seconds)

    # Identity‑based connection – all three parts are required
    SOURCE_STORAGE__blobServiceUri  = var.source_storage_account_blob_endpoint
    SOURCE_STORAGE__queueServiceUri = "https://${var.source_storage_account_name}.queue.core.windows.net/"
    SOURCE_STORAGE__credential      = "managedidentity"

    # Optional: improve Python indexing/startup performance
    PYTHON_ENABLE_INIT_INDEXING = "1"
  }

  tags = var.tags
}
