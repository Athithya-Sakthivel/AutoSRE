locals {
  workbook_name = uuidv5("dns", "serverless-mlops:${var.environment}:workbook")

  workbook_data_json = templatefile("${path.module}/workbook.json.tftpl", {
    workbook_display_name        = var.workbook_display_name
    log_analytics_workspace_name = var.log_analytics_workspace_name
    application_insights_name    = var.application_insights_name
    environment                  = var.environment
  })
}

resource "azurerm_application_insights_workbook" "this" {
  name                = local.workbook_name
  resource_group_name = var.resource_group_name
  location            = var.location
  display_name        = var.workbook_display_name
  source_id           = lower(azurerm_log_analytics_workspace.this.id) # lowercase to pass validation
  category            = "workbook"
  data_json           = local.workbook_data_json

  lifecycle {
    ignore_changes = [display_name] # prevents the hidden-title rename bug
  }

  tags = var.tags
}