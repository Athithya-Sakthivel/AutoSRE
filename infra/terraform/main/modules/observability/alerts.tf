# ============================================================================
# modules/observability/alerts.tf
# Azure Monitor action group and configurable alert rules.
#
# Metric names below use the current Azure Monitor REST metric names for
# Microsoft.ContainerService/managedClusters and
# Microsoft.DBforPostgreSQL/flexibleServers.
# ============================================================================

resource "azurerm_monitor_action_group" "this" {
  name                = "ag-taskapi-${lower(var.environment)}"
  resource_group_name = var.resource_group_name
  short_name          = lower("taskapi${lower(trimspace(var.environment)) == "prod" ? "prod" : "stg"}")
  enabled             = true

  email_receiver {
    name                    = "admin"
    email_address           = var.alert_email_address
    use_common_alert_schema = true
  }

  tags = var.tags
}

# ----------------------------------------------------------------------------
# AKS node CPU usage percentage > 80%
# Current Azure Monitor metric: node_cpu_usage_percentage.
# ----------------------------------------------------------------------------
resource "azurerm_monitor_metric_alert" "cpu" {
  count               = var.enable_cpu_alert ? 1 : 0
  name                = "aks-cpu-${lower(var.environment)}"
  resource_group_name = var.resource_group_name
  scopes              = [var.aks_cluster_id]
  description         = "Alert when average AKS node CPU usage exceeds 80 percent over 15 minutes."
  frequency           = "PT5M"
  window_size         = "PT15M"
  severity            = 2
  auto_mitigate       = true

  criteria {
    metric_namespace = "Microsoft.ContainerService/managedClusters"
    metric_name      = "node_cpu_usage_percentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.this.id
  }

  tags = var.tags
}

# ----------------------------------------------------------------------------
# AKS node memory working-set percentage > 90%
# Current Azure Monitor metric: node_memory_working_set_percentage.
# ----------------------------------------------------------------------------
resource "azurerm_monitor_metric_alert" "memory" {
  count               = var.enable_memory_alert ? 1 : 0
  name                = "aks-memory-${lower(var.environment)}"
  resource_group_name = var.resource_group_name
  scopes              = [var.aks_cluster_id]
  description         = "Alert when average AKS node working-set memory usage exceeds 90 percent over 15 minutes."
  frequency           = "PT5M"
  window_size         = "PT15M"
  severity            = 2
  auto_mitigate       = true

  criteria {
    metric_namespace = "Microsoft.ContainerService/managedClusters"
    metric_name      = "node_memory_working_set_percentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 90
  }

  action {
    action_group_id = azurerm_monitor_action_group.this.id
  }

  tags = var.tags
}

# ----------------------------------------------------------------------------
# Pod restarts > 5 in a 15-minute window.
#
# KubePodInventory exposes PodRestartCount as a cumulative counter. We compare
# the earliest and latest observed value for each pod in the query window,
# rather than summing every observation (which would over-count restarts).
# ----------------------------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "pod_restarts" {
  count                   = var.enable_pod_restarts_alert ? 1 : 0
  name                    = "pod-restarts-${lower(var.environment)}"
  display_name            = "Task API pod restarts - ${var.environment}"
  resource_group_name     = var.resource_group_name
  location                = var.location
  description             = "Alert when the total restart increase across non-system pods exceeds 5 in 15 minutes."
  evaluation_frequency    = "PT15M"
  window_duration         = "PT15M"
  severity                = 2
  enabled                 = true
  auto_mitigation_enabled = true

  scopes = [azurerm_log_analytics_workspace.this.id]

  criteria {
    query = <<-QUERY
      KubePodInventory
      | where TimeGenerated > ago(15m)
      | where Namespace !in ("kube-system", "gatekeeper-system")
      | summarize FirstRestartCount = min(PodRestartCount), LastRestartCount = max(PodRestartCount) by PodUid, Name, Namespace
      | extend Restarts = iif(LastRestartCount > FirstRestartCount, LastRestartCount - FirstRestartCount, 0)
      | summarize TotalRestarts = sum(Restarts)
      | where TotalRestarts > 5
    QUERY

    time_aggregation_method = "Average"
    metric_measure_column   = "TotalRestarts"
    operator                = "GreaterThan"
    threshold               = 5

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  workspace_alerts_storage_enabled = false

  action {
    action_groups = [azurerm_monitor_action_group.this.id]
  }

  tags = var.tags
}

# ----------------------------------------------------------------------------
# PostgreSQL Flexible Server storage > 80%
# Current Azure Monitor metric: storage_percent.
# ----------------------------------------------------------------------------
resource "azurerm_monitor_metric_alert" "postgres_storage" {
  count               = var.enable_postgres_storage_alert ? 1 : 0
  name                = "postgres-storage-${lower(var.environment)}"
  resource_group_name = var.resource_group_name
  scopes              = [var.postgresql_server_id]
  description         = "Alert when PostgreSQL Flexible Server storage usage exceeds 80 percent over 15 minutes."
  frequency           = "PT5M"
  window_size         = "PT15M"
  severity            = 2
  auto_mitigate       = true

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "storage_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.this.id
  }

  tags = var.tags
}

# ----------------------------------------------------------------------------
# Failed Application Insights requests > 5%
#
# The query emits a numeric FailureRate column (0-100). The v2 scheduled query
# rule evaluates that column using Average against a 5% threshold.
# ----------------------------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "failed_requests" {
  count                   = var.enable_failed_requests_alert ? 1 : 0
  name                    = "failed-requests-${lower(var.environment)}"
  display_name            = "Task API failed requests - ${var.environment}"
  resource_group_name     = var.resource_group_name
  location                = var.location
  description             = "Alert when the Application Insights request failure rate exceeds 5 percent."
  evaluation_frequency    = "PT5M"
  window_duration         = "PT15M"
  severity                = 2
  enabled                 = true
  auto_mitigation_enabled = true

  scopes = [azurerm_application_insights.this.id]

  criteria {
    query = <<-QUERY
      AppRequests
      | summarize TotalRequests = sum(ItemCount), FailedRequests = sumif(ItemCount, Success == false) by bin(TimeGenerated, 5m)
      | extend FailureRate = iff(TotalRequests == 0, 0.0, 100.0 * todouble(FailedRequests) / todouble(TotalRequests))
      | project TimeGenerated, FailureRate
    QUERY

    time_aggregation_method = "Average"
    metric_measure_column   = "FailureRate"
    operator                = "GreaterThan"
    threshold               = 5

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  workspace_alerts_storage_enabled = false

  action {
    action_groups = [azurerm_monitor_action_group.this.id]
  }

  tags = var.tags
}
