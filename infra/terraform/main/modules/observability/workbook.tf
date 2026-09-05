resource "azurerm_application_insights_workbook" "this" {
  name                = local.workbook_name
  resource_group_name = var.resource_group_name
  location            = var.location

  display_name = "Task API Observability - ${var.environment}"
  category     = "workbook"

  source_id = local.workbook_workspace_id

  data_json = templatefile("${path.module}/workbook.json.tftpl", {
    environment             = var.environment
    workspace_id            = local.workbook_workspace_id
    application_insights_id = local.workbook_application_insights_id
    request_query           = local.workbook_request_query
    dependency_query        = local.workbook_dependency_query
    exception_query         = local.workbook_exception_query
    metric_query            = local.workbook_metric_query
    snapshot_query          = local.workbook_snapshot_query
  })

  tags = var.tags
}