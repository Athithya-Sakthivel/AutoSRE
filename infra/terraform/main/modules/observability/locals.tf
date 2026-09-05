locals {
  environment_normalized = lower(trimspace(var.environment))

  environment_short = local.environment_normalized == "prod" ? "prod" : "stg"

  workbook_name = uuidv5(
    "url",
    "https://taskapi.example.invalid/observability/workbook/${local.environment_normalized}/${azurerm_application_insights.this.name}"
  )

  workbook_workspace_id = lower(
    azurerm_log_analytics_workspace.this.id
  )

  workbook_application_insights_id = lower(
    azurerm_application_insights.this.id
  )

  workbook_request_query = <<-KQL
    AppRequests
    | where TimeGenerated > ago(24h)
    | where _ResourceId =~ '${local.workbook_application_insights_id}'
    | summarize
        RequestCount = sum(ItemCount),
        FailedCount = sumif(ItemCount, Success == false)
      by bin(TimeGenerated, 1h)
    | extend FailureRate = iff(
        RequestCount == 0,
        0.0,
        100.0 * todouble(FailedCount) / todouble(RequestCount)
      )
    | project TimeGenerated, RequestCount, FailedCount, FailureRate
    | order by TimeGenerated asc
  KQL

  workbook_dependency_query = <<-KQL
    AppDependencies
    | where TimeGenerated > ago(24h)
    | where _ResourceId =~ '${local.workbook_application_insights_id}'
    | summarize
        DependencyCount = sum(ItemCount),
        FailedCount = sumif(ItemCount, Success == false)
      by bin(TimeGenerated, 1h)
    | extend FailureRate = iff(
        DependencyCount == 0,
        0.0,
        100.0 * todouble(FailedCount) / todouble(DependencyCount)
      )
    | project TimeGenerated, DependencyCount, FailedCount, FailureRate
    | order by TimeGenerated asc
  KQL

  workbook_exception_query = <<-KQL
    AppExceptions
    | where TimeGenerated > ago(24h)
    | where _ResourceId =~ '${local.workbook_application_insights_id}'
    | summarize ExceptionCount = sum(ItemCount) by bin(TimeGenerated, 1h)
    | project TimeGenerated, ExceptionCount
    | order by TimeGenerated asc
  KQL

  workbook_metric_query = <<-KQL
    AppMetrics
    | where TimeGenerated > ago(24h)
    | where _ResourceId =~ '${local.workbook_application_insights_id}'
    | summarize
        TotalValue = sum(Sum),
        SampleCount = sum(ItemCount)
      by Name, bin(TimeGenerated, 5m)
    | extend AverageValue = iff(
        SampleCount == 0,
        real(null),
        todouble(TotalValue) / todouble(SampleCount)
      )
    | project TimeGenerated, Name, AverageValue
    | order by TimeGenerated asc
  KQL

  workbook_snapshot_query = <<-KQL
    let TotalRequests = toscalar(
      AppRequests
      | where TimeGenerated > ago(24h)
      | where _ResourceId =~ '${local.workbook_application_insights_id}'
      | summarize sum(ItemCount)
    );
    let FailedRequests = toscalar(
      AppRequests
      | where TimeGenerated > ago(24h)
      | where _ResourceId =~ '${local.workbook_application_insights_id}'
      | where Success == false
      | summarize sum(ItemCount)
    );
    let Dependencies = toscalar(
      AppDependencies
      | where TimeGenerated > ago(24h)
      | where _ResourceId =~ '${local.workbook_application_insights_id}'
      | summarize sum(ItemCount)
    );
    let Exceptions = toscalar(
      AppExceptions
      | where TimeGenerated > ago(24h)
      | where _ResourceId =~ '${local.workbook_application_insights_id}'
      | summarize sum(ItemCount)
    );
    let SafeRequests = tolong(coalesce(TotalRequests, 0));
    let SafeFailedRequests = tolong(coalesce(FailedRequests, 0));
    print
      Requests24h = SafeRequests,
      FailedRequests24h = SafeFailedRequests,
      FailureRate24h = iff(
        SafeRequests == 0,
        0.0,
        100.0 * todouble(SafeFailedRequests) / todouble(SafeRequests)
      ),
      Dependencies24h = tolong(coalesce(Dependencies, 0)),
      Exceptions24h = tolong(coalesce(Exceptions, 0))
  KQL
}