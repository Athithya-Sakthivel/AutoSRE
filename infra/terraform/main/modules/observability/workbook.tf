# ============================================================================
# modules/observability/workbook.tf
# Azure Monitor Workbook for application telemetry.
# ============================================================================

locals {
  # AzureRM requires workbook name to be a lowercase UUID/GUID. Derive a
  # stable UUID-like value from the application + environment so the name is
  # deterministic without requiring a second random provider.
  workbook_name = format(
    "%s-%s-%s-%s-%s",
    substr(md5("task-api-workbook|${lower(var.environment)}|${var.application_insights_name}"), 0, 8),
    substr(md5("task-api-workbook|${lower(var.environment)}|${var.application_insights_name}"), 8, 4),
    substr(md5("task-api-workbook|${lower(var.environment)}|${var.application_insights_name}"), 12, 4),
    substr(md5("task-api-workbook|${lower(var.environment)}|${var.application_insights_name}"), 16, 4),
    substr(md5("task-api-workbook|${lower(var.environment)}|${var.application_insights_name}"), 20, 12)
  )

  workbook_request_query = <<-KQL
    AppRequests
    | summarize RequestCount = sum(ItemCount), FailedCount = sumif(ItemCount, Success == false) by bin(TimeGenerated, 1h)
    | extend FailureRate = iff(RequestCount == 0, 0.0, 100.0 * todouble(FailedCount) / todouble(RequestCount))
    | order by TimeGenerated desc
  KQL

  workbook_dependency_query = <<-KQL
    AppDependencies
    | summarize DependencyCount = sum(ItemCount), FailedCount = sumif(ItemCount, Success == false) by Type, bin(TimeGenerated, 1h)
    | extend FailureRate = iff(DependencyCount == 0, 0.0, 100.0 * todouble(FailedCount) / todouble(DependencyCount))
    | order by TimeGenerated desc
  KQL

  workbook_exception_query = <<-KQL
    AppExceptions
    | summarize ExceptionCount = sum(ItemCount) by Type, bin(TimeGenerated, 1h)
    | order by TimeGenerated desc
  KQL

  workbook_metric_query = <<-KQL
    AppMetrics
    | where Name in ("prediction_latency_ms", "prediction_count", "validation_failures")
    | summarize AverageValue = avg(Value) by Name, bin(TimeGenerated, 5m)
    | order by TimeGenerated desc
  KQL
}

resource "azurerm_application_insights_workbook" "this" {
  name                = local.workbook_name
  resource_group_name = var.resource_group_name
  location            = var.location
  display_name        = "Task API Workbook - ${var.environment}"
  category            = "workbook"

  # The workbook's source is this Application Insights component. The provider
  # requires the source_id to be lowercase.
  source_id = lower(azurerm_application_insights.this.id)

  data_json = templatefile("${path.module}/workbook.json.tftpl", {
    app_insights_id  = lower(azurerm_application_insights.this.id)
    environment      = var.environment
    request_query    = local.workbook_request_query
    dependency_query = local.workbook_dependency_query
    exception_query  = local.workbook_exception_query
    metric_query     = local.workbook_metric_query
  })

  tags = var.tags
}
