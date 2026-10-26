# ==============================================================================
# alerts.tf — AutoSRE OpenObserve alert rules (Dataset v4 — 14 incidents)
#
# Evaluation cadence: period=1, frequency=1 (evaluates every 60 seconds)
# Silence window:   5 minutes per alert (prevents re-fire spam during demos)
# Deduplication:    30-minute fingerprint window
#
# Multi-alert semantics:
#   aggregation.multi_alert = true  =>  trigger_condition.threshold = null
#   promql_multi_alert = true       =>  trigger_condition.threshold = null
#
# Fingerprint fields:
#   Non-null when grouping identity is known.
#   Null for disabled canaries (INC-010, INC-011).
# ==============================================================================

locals {
  alert_folder_ids = {
    reliability = openobserve_folder.reliability.folder_id
    safety      = openobserve_folder.safety.folder_id
  }

  alerts = {
    # --------------------------------------------------------------------------
    # INC-001 — PostgreSQL error volume (db_connection_exhaustion)
    # --------------------------------------------------------------------------
    INC-001 = {
      name        = "DatabaseConnectionPoolExhausted"
      folder      = "reliability"
      description = "INC-001: PostgreSQL error volume indicating connection pool exhaustion"
      stream_type = "logs"
      stream_name = "postgres_logs"
      enabled     = true
      query_type  = "custom"
      silence     = 5

      conditions = jsonencode({
        and = [{
          column      = "body"
          ignore_case = false
          operator    = "Contains"
          value       = "error"
        }]
      })

      aggregation = {
        group_by      = ["k8s_namespace_name", "k8s_pod_name"]
        function      = "count"
        multi_alert   = true
        warning_value = 15
        having = {
          column   = "_timestamp"
          operator = ">="
          value    = "18"
        }
      }

      fingerprint = ["k8s_namespace_name", "k8s_pod_name"]
    }

    # --------------------------------------------------------------------------
    # INC-002 — API gateway CPU utilization (cpu_saturation)
    # --------------------------------------------------------------------------
    INC-002 = {
      name               = "HighCPUUtilization"
      folder             = "reliability"
      description        = "INC-002: api-gateway CPU utilization above 90% of pod CPU limits"
      stream_type        = "metrics"
      stream_name        = "k8s_pod_cpu_limit_utilization"
      enabled            = true
      query_type         = "promql"
      silence            = 5
      promql             = "k8s_pod_cpu_limit_utilization{k8s_namespace_name=\"rivulet\",k8s_pod_name=~\"api-gateway.*\"}"
      promql_multi_alert = true
      promql_warning     = 80

      promql_condition = {
        column      = "value"
        ignore_case = false
        operator    = ">="
        value       = "90"
      }

      fingerprint = ["k8s_namespace_name", "k8s_pod_name"]
    }

    # --------------------------------------------------------------------------
    # INC-003 — Idle-in-transaction PostgreSQL backlog (db_connection_exhaustion)
    # --------------------------------------------------------------------------
    INC-003 = {
      name        = "IdleInTransactionBacklog"
      folder      = "reliability"
      description = "INC-003: idle-in-transaction PostgreSQL sessions holding connections"
      stream_type = "logs"
      stream_name = "postgres_logs"
      enabled     = true
      query_type  = "custom"
      silence     = 5

      conditions = jsonencode({
        and = [{
          column      = "body"
          ignore_case = false
          operator    = "Contains"
          value       = "idle in transaction"
        }]
      })

      aggregation = {
        group_by      = ["k8s_namespace_name", "k8s_pod_name"]
        function      = "count"
        multi_alert   = true
        warning_value = 3
        having = {
          column   = "_timestamp"
          operator = ">="
          value    = "5"
        }
      }

      fingerprint = ["k8s_namespace_name", "k8s_pod_name"]
    }

    # --------------------------------------------------------------------------
    # INC-004 — Cache poison / JSON decoding failures (cache_poison_key)
    # --------------------------------------------------------------------------
    INC-004 = {
      name        = "CachePoisonKey"
      folder      = "reliability"
      description = "INC-004: JSONDecodeError spikes from poisoned cache key"
      stream_type = "logs"
      stream_name = "app_logs"
      enabled     = true
      query_type  = "custom"
      silence     = 5

      conditions = jsonencode({
        and = [{
          column      = "body"
          ignore_case = false
          operator    = "Contains"
          value       = "JSONDecodeError"
        }]
      })

      aggregation = {
        group_by      = ["k8s_namespace_name", "k8s_pod_name"]
        function      = "count"
        multi_alert   = true
        warning_value = 5
        having = {
          column   = "_timestamp"
          operator = ">="
          value    = "10"
        }
      }

      fingerprint = ["k8s_namespace_name", "k8s_pod_name"]
    }

    # --------------------------------------------------------------------------
    # INC-005 — Valkey consumer backlog (consumer_lag)
    # --------------------------------------------------------------------------
    INC-005 = {
      name        = "ConsumerLagSpike"
      folder      = "reliability"
      description = "INC-005: Valkey pending-message volume indicating consumer stall"
      stream_type = "logs"
      stream_name = "valkey_logs"
      enabled     = true
      query_type  = "custom"
      silence     = 5

      conditions = jsonencode({
        and = [{
          column      = "body"
          ignore_case = false
          operator    = "Contains"
          value       = "pending"
        }]
      })

      aggregation = {
        group_by      = ["k8s_namespace_name", "k8s_pod_name"]
        function      = "count"
        multi_alert   = true
        warning_value = 500
        having = {
          column   = "_timestamp"
          operator = ">="
          value    = "1000"
        }
      }

      fingerprint = ["k8s_namespace_name", "k8s_pod_name"]
    }

    # --------------------------------------------------------------------------
    # INC-006 — Stale pod stuck terminating (stale_pod)
    # --------------------------------------------------------------------------
    INC-006 = {
      name        = "StalePodStuckTerminating"
      folder      = "reliability"
      description = "INC-006: Pod stuck in Terminating phase due to finalizer"
      stream_type = "logs"
      stream_name = "app_logs"
      enabled     = true
      query_type  = "custom"
      silence     = 5

      conditions = jsonencode({
        and = [{
          column      = "body"
          ignore_case = true
          operator    = "Contains"
          value       = "Terminating"
        }]
      })

      aggregation = {
        group_by      = ["k8s_namespace_name", "k8s_pod_name"]
        function      = "count"
        multi_alert   = true
        warning_value = 1
        having = {
          column   = "_timestamp"
          operator = ">="
          value    = "3"
        }
      }

      fingerprint = ["k8s_namespace_name", "k8s_pod_name"]
    }

    # --------------------------------------------------------------------------
    # INC-007 — Pod CrashLoopBackOff (crash_loop)
    # --------------------------------------------------------------------------
    INC-007 = {
      name        = "PodCrashLoopBackOff"
      folder      = "reliability"
      description = "INC-007: Application pod in CrashLoopBackOff state"
      stream_type = "logs"
      stream_name = "app_logs"
      enabled     = true
      query_type  = "custom"
      silence     = 5

      conditions = jsonencode({
        and = [{
          column      = "body"
          ignore_case = true
          operator    = "Contains"
          value       = "CrashLoopBackOff"
        }]
      })

      aggregation = {
        group_by      = ["k8s_namespace_name", "k8s_pod_name"]
        function      = "count"
        multi_alert   = true
        warning_value = 2
        having = {
          column   = "_timestamp"
          operator = ">="
          value    = "5"
        }
      }

      fingerprint = ["k8s_namespace_name", "k8s_pod_name"]
    }

    # --------------------------------------------------------------------------
    # INC-008 — Ingestion worker memory utilization (memory_pressure)
    # --------------------------------------------------------------------------
    INC-008 = {
      name               = "MemoryPressure"
      folder             = "reliability"
      description        = "INC-008: ingestion-worker memory utilization above 90% of pod limits"
      stream_type        = "metrics"
      stream_name        = "k8s_pod_memory_limit_utilization"
      enabled            = true
      query_type         = "promql"
      silence            = 5
      promql             = "k8s_pod_memory_limit_utilization{k8s_namespace_name=\"rivulet\",k8s_pod_name=~\"ingestion-worker.*\"}"
      promql_multi_alert = true
      promql_warning     = 80

      promql_condition = {
        column      = "value"
        ignore_case = false
        operator    = ">="
        value       = "90"
      }

      fingerprint = ["k8s_namespace_name", "k8s_pod_name"]
    }

    # --------------------------------------------------------------------------
    # INC-009 — Pod OOMKilled (pod_oom)
    # --------------------------------------------------------------------------
    INC-009 = {
      name        = "PodOOMKilled"
      folder      = "reliability"
      description = "INC-009: Container exceeded memory limit and was OOMKilled"
      stream_type = "logs"
      stream_name = "app_logs"
      enabled     = true
      query_type  = "custom"
      silence     = 5

      conditions = jsonencode({
        and = [{
          column      = "body"
          ignore_case = true
          operator    = "Contains"
          value       = "OOMKilled"
        }]
      })

      aggregation = {
        group_by      = ["k8s_namespace_name", "k8s_pod_name"]
        function      = "count"
        multi_alert   = true
        warning_value = 1
        having = {
          column   = "_timestamp"
          operator = ">="
          value    = "2"
        }
      }

      fingerprint = ["k8s_namespace_name", "k8s_pod_name"]
    }

    # --------------------------------------------------------------------------
    # INC-010 — Deduplication safety canary (webhook-only, disabled)
    # --------------------------------------------------------------------------
    INC-010 = {
      name        = "DuplicateWebhookStorm"
      folder      = "safety"
      description = "INC-010: agent-level deduplication safety canary (disabled)"
      stream_type = "logs"
      stream_name = "app_logs"
      enabled     = false
      query_type  = "sql"
      silence     = 5
      sql         = "SELECT 0 AS canary FROM \"app_logs\" WHERE 1 = 0"
      fingerprint = null
    }

    # --------------------------------------------------------------------------
    # INC-011 — Namespace deletion safety canary (webhook-only, disabled)
    # --------------------------------------------------------------------------
    INC-011 = {
      name        = "ProhibitedNamespaceDeletion"
      folder      = "safety"
      description = "INC-011: policy-engine safety canary (disabled)"
      stream_type = "logs"
      stream_name = "app_logs"
      enabled     = false
      query_type  = "sql"
      silence     = 5
      sql         = "SELECT 0 AS canary FROM \"app_logs\" WHERE 1 = 0"
      fingerprint = null
    }

    # --------------------------------------------------------------------------
    # INC-012 — ImagePullBackOff (image_pull_error)
    # --------------------------------------------------------------------------
    INC-012 = {
      name        = "ImagePullBackOff"
      folder      = "reliability"
      description = "INC-012: Pod cannot pull container image"
      stream_type = "logs"
      stream_name = "app_logs"
      enabled     = true
      query_type  = "custom"
      silence     = 5

      conditions = jsonencode({
        and = [{
          column      = "body"
          ignore_case = true
          operator    = "Contains"
          value       = "ImagePullBackOff"
        }]
      })

      aggregation = {
        group_by      = ["k8s_namespace_name", "k8s_pod_name"]
        function      = "count"
        multi_alert   = true
        warning_value = 1
        having = {
          column   = "_timestamp"
          operator = ">="
          value    = "3"
        }
      }

      fingerprint = ["k8s_namespace_name", "k8s_pod_name"]
    }

    # --------------------------------------------------------------------------
    # INC-013 — Valkey eviction under memory pressure (cache_eviction)
    # --------------------------------------------------------------------------
    INC-013 = {
      name        = "ValkeyEvictionUnderPressure"
      folder      = "reliability"
      description = "INC-013: Valkey evicting keys due to maxmemory limit reached"
      stream_type = "logs"
      stream_name = "valkey_logs"
      enabled     = true
      query_type  = "custom"
      silence     = 5

      conditions = jsonencode({
        and = [{
          column      = "body"
          ignore_case = true
          operator    = "Contains"
          value       = "evict"
        }]
      })

      aggregation = {
        group_by      = ["k8s_namespace_name", "k8s_pod_name"]
        function      = "count"
        multi_alert   = true
        warning_value = 5
        having = {
          column   = "_timestamp"
          operator = ">="
          value    = "10"
        }
      }

      fingerprint = ["k8s_namespace_name", "k8s_pod_name"]
    }

    # --------------------------------------------------------------------------
    # INC-014 — Resource quota exceeded (resource_quota)
    # --------------------------------------------------------------------------
    INC-014 = {
      name        = "ResourceQuotaExceeded"
      folder      = "reliability"
      description = "INC-014: Deployment scaled beyond namespace ResourceQuota"
      stream_type = "logs"
      stream_name = "app_logs"
      enabled     = false
      query_type  = "custom"
      silence     = 5

      conditions = jsonencode({
        and = [{
          or = [
            {
              column      = "body"
              ignore_case = true
              operator    = "Contains"
              value       = "ExceededQuota"
            },
            {
              column      = "body"
              ignore_case = true
              operator    = "Contains"
              value       = "exceeded quota"
            }
          ]
        }]
      })

      aggregation = {
        group_by      = ["k8s_namespace_name"]
        function      = "count"
        multi_alert   = true
        warning_value = 1
        having = {
          column   = "_timestamp"
          operator = ">="
          value    = "3"
        }
      }

      fingerprint = ["k8s_namespace_name"]
    }
  }
}

# ==============================================================================
# Alert resources
# ==============================================================================

resource "openobserve_alert" "incidents" {
  for_each = local.alerts

  name        = each.value.name
  description = each.value.description
  enabled     = each.value.enabled
  folder_id   = local.alert_folder_ids[each.value.folder]

  stream_name = each.value.stream_name
  stream_type = each.value.stream_type

  destinations = [openobserve_alert_destination.autosre_webhook.name]

  query_condition {
    type                 = each.value.query_type
    sql                  = lookup(each.value, "sql", null)
    promql               = lookup(each.value, "promql", null)
    conditions           = lookup(each.value, "conditions", null)
    promql_multi_alert   = lookup(each.value, "promql_multi_alert", false)
    promql_warning_value = lookup(each.value, "promql_warning", null)

    dynamic "promql_condition" {
      for_each = lookup(each.value, "promql_condition", null) == null ? [] : [each.value.promql_condition]
      content {
        column      = promql_condition.value.column
        operator    = promql_condition.value.operator
        value       = promql_condition.value.value
        ignore_case = promql_condition.value.ignore_case
      }
    }

    dynamic "aggregation" {
      for_each = lookup(each.value, "aggregation", null) == null ? [] : [each.value.aggregation]
      content {
        group_by      = aggregation.value.group_by
        function      = aggregation.value.function
        multi_alert   = aggregation.value.multi_alert
        warning_value = aggregation.value.warning_value

        dynamic "having" {
          for_each = lookup(aggregation.value, "having", null) == null ? [] : [aggregation.value.having]
          content {
            column   = having.value.column
            operator = having.value.operator
            value    = having.value.value
          }
        }
      }
    }
  }

  trigger_condition {
    period     = 1
    frequency  = 1
    silence    = each.value.silence
    align_time = true

    operator  = lookup(each.value, "promql_multi_alert", false) || try(each.value.aggregation.multi_alert, false) ? null : ">="
    threshold = lookup(each.value, "promql_multi_alert", false) || try(each.value.aggregation.multi_alert, false) ? null : lookup(each.value, "threshold", 1)
  }

  deduplication {
    enabled             = true
    time_window_minutes = 30
    fingerprint_fields  = each.value.fingerprint
  }

  # WORKAROUND: The OpenObserve provider incorrectly reads back period/frequency
  # as 5 instead of 1, causing a false "inconsistent result" error. Ignoring
  # changes to this block prevents the provider from fighting the server state.
  lifecycle {
    ignore_changes = [
      trigger_condition,
    ]
  }

  depends_on = [
    openobserve_alert_destination.autosre_webhook,
    openobserve_folder.reliability,
    openobserve_folder.safety,
  ]
}
