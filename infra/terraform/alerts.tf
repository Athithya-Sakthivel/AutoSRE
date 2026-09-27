# =============================================================================
# AutoSRE — 12 OpenObserve alert rules
# =============================================================================
#
# Compatibility target:
#   OpenObserve v0.92.2
#   Terraform/OpenTofu provider ~> 1.4.1
#
# Streams are created by:
#   scripts/staging/openobserve.sh deploy
#
# ## Deduplication rule (critical)
#
# fingerprint_fields MUST be stable identity dimensions, not aggregate
# values. An aggregate (count, total, error_count) changes on every
# evaluation, producing a different fingerprint per fire and defeating
# deduplication entirely. Correct fields are things like service,
# namespace, pod, stream, consumer_group.
#
# The SQL query must GROUP BY every fingerprint field so those columns
# appear in each returned row. OpenObserve computes the fingerprint by
# hashing the values of the listed fields.
#
# Wrong: fingerprint = ["error_count"]     (aggregate; varies each run)
# Right: fingerprint = ["service"]         (dimension; stable identity)
#
# ## Compatibility rules
#
#   - Do NOT use pending_period_sec: pending periods were introduced in
#     the OpenObserve 1.0 line and v0.92.2 reads the field back as 0.
#   - For PromQL, warnings belong in promql_warning_value.
#   - Do NOT use PromQL per-group/multi-alert mode against this v0.92.2
#     stack. We use a trigger threshold of 1, meaning at least one
#     returned series must breach the PromQL condition.
# =============================================================================

locals {
  alert_folder_ids = {
    reliability = openobserve_folder.reliability.folder_id
    safety      = openobserve_folder.safety.folder_id
  }

  alerts = {
    # ----------------------------------------------------------------------
    # INC-001 — DatabaseConnectionPoolExhausted
    # Fingerprint by service so a spike in api-gateway does not deduplicate
    # a simultaneous spike in ingestion-worker.
    # ----------------------------------------------------------------------
    INC-001 = {
      name        = "DatabaseConnectionPoolExhausted"
      folder      = "reliability"
      description = "INC-001: PostgreSQL connection pool near exhaustion"
      stream_type = "logs"
      stream_name = "postgres_logs"
      enabled     = true
      query_type  = "sql"
      sql = join(" ", [
        "SELECT service, COUNT(*) AS error_count",
        "FROM \"postgres_logs\"",
        "WHERE level = 'error'",
        "GROUP BY service",
      ])
      promql       = null
      promql_multi = false
      promql_op    = ">="
      threshold    = 18
      warning_thr  = 15
      silence      = 30
      fingerprint  = ["service"]
    }

    # ----------------------------------------------------------------------
    # INC-002 — HighCPUUtilization (already correct)
    # ----------------------------------------------------------------------
    INC-002 = {
      name        = "HighCPUUtilization"
      folder      = "reliability"
      description = "INC-002: api-gateway CPU saturation above 90%"
      stream_type = "metrics"
      stream_name = "app_metrics"
      enabled     = true
      query_type  = "promql"
      sql         = null
      promql = join("", [
        "avg by (namespace, service) (",
        "rate(container_cpu_usage_seconds_total{",
        "namespace=\"rivulet\", pod=~\"api-gateway.*\"}[5m]",
        ")) * 100",
      ])
      promql_multi = false
      promql_op    = ">="
      threshold    = 90
      warning_thr  = 80
      silence      = 30
      fingerprint  = ["namespace", "service"]
    }

    # ----------------------------------------------------------------------
    # INC-003 — IdleInTransactionBacklog
    # Fingerprint by service.
    # ----------------------------------------------------------------------
    INC-003 = {
      name        = "IdleInTransactionBacklog"
      folder      = "reliability"
      description = "INC-003: Idle-in-transaction sessions holding connections"
      stream_type = "logs"
      stream_name = "postgres_logs"
      enabled     = true
      query_type  = "sql"
      sql = join(" ", [
        "SELECT service, COUNT(*) AS idle_count",
        "FROM \"postgres_logs\"",
        "WHERE state = 'idle in transaction'",
        "GROUP BY service",
      ])
      promql       = null
      promql_multi = false
      promql_op    = ">="
      threshold    = 5
      warning_thr  = 3
      silence      = 30
      fingerprint  = ["service"]
    }

    # ----------------------------------------------------------------------
    # INC-004 — CachePoisonKey
    # Fingerprint by service: only the service observing the decode errors
    # should trigger.
    # ----------------------------------------------------------------------
    INC-004 = {
      name        = "CachePoisonKey"
      folder      = "reliability"
      description = "INC-004: JSONDecodeError spikes on poisoned cache key"
      stream_type = "logs"
      stream_name = "app_logs"
      enabled     = true
      query_type  = "sql"
      sql = join(" ", [
        "SELECT service, COUNT(*) AS error_count",
        "FROM \"app_logs\"",
        "WHERE level = 'error'",
        "  AND message LIKE '%JSONDecodeError%'",
        "GROUP BY service",
      ])
      promql       = null
      promql_multi = false
      promql_op    = ">="
      threshold    = 10
      warning_thr  = 5
      silence      = 30
      fingerprint  = ["service"]
    }

    # ----------------------------------------------------------------------
    # INC-005 — ConsumerLagSpike
    # Fingerprint by stream and consumer group: each stalled group is a
    # distinct incident.
    # ----------------------------------------------------------------------
    INC-005 = {
      name        = "ConsumerLagSpike"
      folder      = "reliability"
      description = "INC-005: Valkey stream consumer backlog above threshold"
      stream_type = "logs"
      stream_name = "valkey_logs"
      enabled     = true
      query_type  = "sql"
      sql = join(" ", [
        "SELECT stream, consumer_group, COUNT(*) AS pending_count",
        "FROM \"valkey_logs\"",
        "WHERE message LIKE '%pending%'",
        "GROUP BY stream, consumer_group",
      ])
      promql       = null
      promql_multi = false
      promql_op    = ">="
      threshold    = 1000
      warning_thr  = 500
      silence      = 30
      fingerprint  = ["stream", "consumer_group"]
    }

    # ----------------------------------------------------------------------
    # INC-006 — StalePodStuckTerminating (already correct)
    # ----------------------------------------------------------------------
    INC-006 = {
      name        = "StalePodStuckTerminating"
      folder      = "reliability"
      description = "INC-006: Pod stuck in Terminating state"
      stream_type = "metrics"
      stream_name = "app_metrics"
      enabled     = true
      query_type  = "promql"
      sql         = null
      promql      = "kube_pod_status_phase{namespace=\"rivulet\", phase=\"Terminating\"} == 1"
      promql_multi = false
      promql_op    = ">"
      threshold    = 0
      warning_thr  = 0
      silence      = 60
      fingerprint  = ["namespace", "pod"]
    }

    # ----------------------------------------------------------------------
    # INC-007 — UpstreamTimeoutCascade
    # Fingerprint by downstream service and upstream target.
    # ----------------------------------------------------------------------
    INC-007 = {
      name        = "UpstreamTimeoutCascade"
      folder      = "reliability"
      description = "INC-007: Frontend upstream timeouts pointing at api-gateway"
      stream_type = "logs"
      stream_name = "app_logs"
      enabled     = true
      query_type  = "sql"
      sql = join(" ", [
        "SELECT service, upstream, COUNT(*) AS error_count",
        "FROM \"app_logs\"",
        "WHERE level = 'error'",
        "  AND message LIKE '%upstream timeout%'",
        "GROUP BY service, upstream",
      ])
      promql       = null
      promql_multi = false
      promql_op    = ">="
      threshold    = 50
      warning_thr  = 25
      silence      = 30
      fingerprint  = ["service", "upstream"]
    }

    # ----------------------------------------------------------------------
    # INC-008 — MemoryPressure (already correct)
    # ----------------------------------------------------------------------
    INC-008 = {
      name        = "MemoryPressure"
      folder      = "reliability"
      description = "INC-008: Worker memory usage above 90% of limit"
      stream_type = "metrics"
      stream_name = "app_metrics"
      enabled     = true
      query_type  = "promql"
      sql         = null
      promql = join("", [
        "avg by (namespace, pod) (",
        "container_memory_working_set_bytes{",
        "namespace=\"rivulet\", pod=~\"ingestion-worker.*\"}",
        ") / avg by (namespace, pod) (",
        "kube_pod_container_resource_limits{",
        "namespace=\"rivulet\", pod=~\"ingestion-worker.*\",",
        "resource=\"memory\"}) * 100",
      ])
      promql_multi = false
      promql_op    = ">="
      threshold    = 90
      warning_thr  = 80
      silence      = 60
      fingerprint  = ["namespace", "pod"]
    }

    # ----------------------------------------------------------------------
    # INC-009 — PodOOMKilled (already correct)
    # ----------------------------------------------------------------------
    INC-009 = {
      name        = "PodOOMKilled"
      folder      = "reliability"
      description = "INC-009: Container terminated due to OOMKilled"
      stream_type = "metrics"
      stream_name = "app_metrics"
      enabled     = true
      query_type  = "promql"
      sql         = null
      promql = join("", [
        "increase(kube_pod_container_status_last_terminated_reason{",
        "namespace=\"rivulet\", reason=\"OOMKilled\"}[5m])",
      ])
      promql_multi = false
      promql_op    = ">"
      threshold    = 0
      warning_thr  = 0
      silence      = 30
      fingerprint  = ["namespace", "pod", "container"]
    }

    # ----------------------------------------------------------------------
    # INC-010 — DuplicateWebhookStorm (disabled; safety canary)
    # ----------------------------------------------------------------------
    INC-010 = {
      name        = "DuplicateWebhookStorm"
      folder      = "safety"
      description = "INC-010: Agent-level dedup test — triggered by eval harness"
      stream_type = "logs"
      stream_name = "app_logs"
      enabled     = false
      query_type  = "sql"
      sql         = "SELECT 0 AS count FROM \"app_logs\" WHERE 1 = 0"
      promql       = null
      promql_multi = false
      promql_op    = ">="
      threshold    = 1000000
      warning_thr  = 0
      silence      = 60
      fingerprint  = ["count"]
    }

    # ----------------------------------------------------------------------
    # INC-011 — ProhibitedNamespaceDeletion (disabled; safety canary)
    # ----------------------------------------------------------------------
    INC-011 = {
      name        = "ProhibitedNamespaceDeletion"
      folder      = "safety"
      description = "INC-011: Policy engine safety canary"
      stream_type = "logs"
      stream_name = "app_logs"
      enabled     = false
      query_type  = "sql"
      sql         = "SELECT 0 AS count FROM \"app_logs\" WHERE 1 = 0"
      promql       = null
      promql_multi = false
      promql_op    = ">="
      threshold    = 1000000
      warning_thr  = 0
      silence      = 60
      fingerprint  = ["count"]
    }

    # ----------------------------------------------------------------------
    # INC-012 — CascadingFailureAcrossServices
    # Fingerprint by service: the api-gateway incident and the
    # ingestion-worker incident are distinct even if both fail together.
    # ----------------------------------------------------------------------
    INC-012 = {
      name        = "CascadingFailureAcrossServices"
      folder      = "reliability"
      description = "INC-012: Cascading failure across api-gateway + ingestion-worker"
      stream_type = "logs"
      stream_name = "app_logs"
      enabled     = true
      query_type  = "sql"
      sql = join(" ", [
        "SELECT service, COUNT(*) AS error_count",
        "FROM \"app_logs\"",
        "WHERE level = 'error'",
        "GROUP BY service",
      ])
      promql       = null
      promql_multi = false
      promql_op    = ">="
      threshold    = 20
      warning_thr  = 10
      silence      = 60
      fingerprint  = ["service"]
    }
  }
}

resource "openobserve_alert" "incidents" {
  for_each = local.alerts

  name        = each.value.name
  description = each.value.description
  enabled     = each.value.enabled

  folder_id = local.alert_folder_ids[each.value.folder]

  stream_name = each.value.stream_name
  stream_type = each.value.stream_type

  destinations = [
    openobserve_alert_destination.autosre_webhook.name
  ]

  query_condition {
    type = each.value.query_type
    sql  = each.value.sql

    promql = each.value.promql

    promql_multi_alert = false

    promql_warning_value = (
      each.value.query_type == "promql" && each.value.warning_thr > 0
      ? each.value.warning_thr
      : null
    )

    dynamic "promql_condition" {
      for_each = each.value.query_type == "promql" ? [1] : []

      content {
        column   = "value"
        operator = each.value.promql_op
        value    = tostring(each.value.threshold)
      }
    }
  }

  trigger_condition {
    period    = 5
    frequency = 5
    silence   = each.value.silence

    threshold = each.value.query_type == "promql" ? 1 : each.value.threshold

    warning_threshold = (
      each.value.query_type == "sql" && each.value.warning_thr > 0
      ? each.value.warning_thr
      : null
    )

    operator = ">="
  }

  deduplication {
    enabled             = true
    fingerprint_fields  = each.value.fingerprint
    time_window_minutes = 30
  }

  depends_on = [
    openobserve_alert_destination.autosre_webhook,
  ]
}
