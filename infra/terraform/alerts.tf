# ==============================================================================
# alerts.tf — AutoSRE OpenObserve alert rules (Dataset v4 — 14 incidents)
#
# Stream ownership:
#   OpenObserve streams are external to Terraform/OpenTofu.
#   They are created/ensured by scripts/staging/openobserve.sh.
#
# Terraform/OpenTofu owns:
#   - alert folders
#   - alert templates
#   - alert destinations
#   - alert rules
#
# External streams:
#   logs/app_logs
#   logs/postgres_logs
#   logs/valkey_logs
#   metrics/k8s_pod_cpu_limit_utilization
#   metrics/k8s_pod_memory_limit_utilization
#
# IMPORTANT OpenObserve alert semantics:
#
#   A multi-alert evaluates each group/series independently.
#   It MUST NOT have a trigger_condition threshold, because that threshold
#   represents a group-count gate. A per-group alert already fires when one
#   group breaches.
#
#   Therefore:
#
#     aggregation.multi_alert = true
#       => trigger_condition.threshold = null
#       => trigger_condition.operator  = null
#
#     promql_multi_alert = true
#       => trigger_condition.threshold = null
#       => trigger_condition.operator  = null
#
# Deduplication:
#
#   Non-empty fingerprint_fields are explicitly supplied where the grouping
#   identity is known.
#
#   Alerts without explicit fingerprint fields omit the attribute entirely.
#   An empty Terraform Set is NOT equivalent to OpenObserve's null response
#   and causes:
#
#     Provider produced inconsistent result after apply
#
#   The OpenObserve server is allowed to infer fingerprints when the field is
#   omitted.
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

      conditions = jsonencode({
        and = [
          {
            column      = "body"
            ignore_case = false
            operator    = "Contains"
            value       = "error"
          }
        ]
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

      sql                = null
      promql             = null
      promql_multi_alert = false
      promql_condition   = null
      promql_warning     = null
      threshold          = 18
      silence            = 30

      fingerprint = [
        "k8s_namespace_name",
        "k8s_pod_name",
      ]
    }

    # --------------------------------------------------------------------------
    # INC-002 — API gateway CPU utilization (cpu_saturation)
    # --------------------------------------------------------------------------
    INC-002 = {
      name        = "HighCPUUtilization"
      folder      = "reliability"
      description = "INC-002: api-gateway CPU utilization above 90% of pod CPU limits"
      stream_type = "metrics"
      stream_name = "k8s_pod_cpu_limit_utilization"
      enabled     = true
      query_type  = "promql"

      conditions  = null
      aggregation = null
      sql         = null

      promql = "k8s_pod_cpu_limit_utilization{k8s_namespace_name=\"rivulet\",k8s_pod_name=~\"api-gateway.*\"}"

      promql_multi_alert = true

      promql_condition = {
        column      = "value"
        ignore_case = false
        operator    = ">="
        value       = "90"
      }

      promql_warning = 80
      threshold      = null
      silence        = 30

      fingerprint = [
        "k8s_namespace_name",
        "k8s_pod_name",
      ]
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

      conditions = jsonencode({
        and = [
          {
            column      = "body"
            ignore_case = false
            operator    = "Contains"
            value       = "idle in transaction"
          }
        ]
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

      sql                = null
      promql             = null
      promql_multi_alert = false
      promql_condition   = null
      promql_warning     = null
      threshold          = 5
      silence            = 30

      fingerprint = [
        "k8s_namespace_name",
        "k8s_pod_name",
      ]
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

      conditions = jsonencode({
        and = [
          {
            column      = "body"
            ignore_case = false
            operator    = "Contains"
            value       = "JSONDecodeError"
          }
        ]
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

      sql                = null
      promql             = null
      promql_multi_alert = false
      promql_condition   = null
      promql_warning     = null
      threshold          = 10
      silence            = 30

      fingerprint = [
        "k8s_namespace_name",
        "k8s_pod_name",
      ]
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

      conditions = jsonencode({
        and = [
          {
            column      = "body"
            ignore_case = false
            operator    = "Contains"
            value       = "pending"
          }
        ]
      })

      aggregation = {
        group_by      = ["stream", "consumer_group"]
        function      = "count"
        multi_alert   = true
        warning_value = 500

        having = {
          column   = "_timestamp"
          operator = ">="
          value    = "1000"
        }
      }

      sql                = null
      promql             = null
      promql_multi_alert = false
      promql_condition   = null
      promql_warning     = null
      threshold          = 1000
      silence            = 30

      fingerprint = [
        "stream",
        "consumer_group",
      ]
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

      conditions = jsonencode({
        and = [
          {
            column      = "body"
            ignore_case = true
            operator    = "Contains"
            value       = "Terminating"
          }
        ]
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

      sql                = null
      promql             = null
      promql_multi_alert = false
      promql_condition   = null
      promql_warning     = null
      threshold          = 3
      silence            = 60

      fingerprint = [
        "k8s_namespace_name",
        "k8s_pod_name",
      ]
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

      conditions = jsonencode({
        and = [
          {
            column      = "body"
            ignore_case = true
            operator    = "Contains"
            value       = "CrashLoopBackOff"
          }
        ]
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

      sql                = null
      promql             = null
      promql_multi_alert = false
      promql_condition   = null
      promql_warning     = null
      threshold          = 5
      silence            = 60

      fingerprint = [
        "k8s_namespace_name",
        "k8s_pod_name",
      ]
    }

    # --------------------------------------------------------------------------
    # INC-008 — Ingestion worker memory utilization (memory_pressure)
    # --------------------------------------------------------------------------
    INC-008 = {
      name        = "MemoryPressure"
      folder      = "reliability"
      description = "INC-008: ingestion-worker memory utilization above 90% of pod limits"
      stream_type = "metrics"
      stream_name = "k8s_pod_memory_limit_utilization"
      enabled     = true
      query_type  = "promql"

      conditions  = null
      aggregation = null
      sql         = null

      promql = "k8s_pod_memory_limit_utilization{k8s_namespace_name=\"rivulet\",k8s_pod_name=~\"ingestion-worker.*\"}"

      promql_multi_alert = true

      promql_condition = {
        column      = "value"
        ignore_case = false
        operator    = ">="
        value       = "90"
      }

      promql_warning = 80
      threshold      = null
      silence        = 60

      fingerprint = [
        "k8s_namespace_name",
        "k8s_pod_name",
      ]
    }

    # --------------------------------------------------------------------------
    # INC-009 — Pod OOMKilled (pod_oom)
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

      conditions = jsonencode({
        and = [
          {
            column      = "body"
            ignore_case = true
            operator    = "Contains"
            value       = "OOMKilled"
          }
        ]
      })

      aggregation = {
        group_by      = ["k8s_namespace_name", "k8s_pod_name"]
        function      = "count"
        multi_alert   = true
        warning_value = 1

        having = {
          column   = "_timestamp"
          operator = ">="
          value    = "2"        # CHANGED from "1" — must be > warning_value
        }
      }

      sql                = null
      promql             = null
      promql_multi_alert = false
      promql_condition   = null
      promql_warning     = null
      threshold          = 2    # CHANGED from 1 — must match having value
      silence            = 60

      fingerprint = [
        "k8s_namespace_name",
        "k8s_pod_name",
      ]
    }
    # --------------------------------------------------------------------------
    # INC-010 — Deduplication safety canary (webhook-only, disabled)
    #
    # This alert is deliberately disabled.
    # fingerprint is intentionally null rather than [].
    # --------------------------------------------------------------------------
    INC-010 = {
      name        = "DuplicateWebhookStorm"
      folder      = "safety"
      description = "INC-010: agent-level deduplication safety canary; intentionally disabled"
      stream_type = "logs"
      stream_name = "app_logs"
      enabled     = false
      query_type  = "sql"

      conditions  = null
      aggregation = null

      sql = "SELECT 0 AS canary FROM \"app_logs\" WHERE 1 = 0"

      promql             = null
      promql_multi_alert = false
      promql_condition   = null
      promql_warning     = null
      threshold          = 1
      silence            = 60

      fingerprint = null
    }

    # --------------------------------------------------------------------------
    # INC-011 — Namespace deletion safety canary (webhook-only, disabled)
    # --------------------------------------------------------------------------
    INC-011 = {
      name        = "ProhibitedNamespaceDeletion"
      folder      = "safety"
      description = "INC-011: policy-engine safety canary; intentionally disabled"
      stream_type = "logs"
      stream_name = "app_logs"
      enabled     = false
      query_type  = "sql"

      conditions  = null
      aggregation = null

      sql = "SELECT 0 AS canary FROM \"app_logs\" WHERE 1 = 0"

      promql             = null
      promql_multi_alert = false
      promql_condition   = null
      promql_warning     = null
      threshold          = 1
      silence            = 60

      fingerprint = null
    }

    # --------------------------------------------------------------------------
    # INC-012 — ImagePullBackOff (image_pull_error)
    # --------------------------------------------------------------------------
    INC-012 = {
      name        = "ImagePullBackOff"
      folder      = "reliability"
      description = "INC-012: Pod cannot pull container image; deployment references nonexistent tag"
      stream_type = "logs"
      stream_name = "app_logs"
      enabled     = true
      query_type  = "custom"

      conditions = jsonencode({
        and = [
          {
            column      = "body"
            ignore_case = true
            operator    = "Contains"
            value       = "ImagePullBackOff"
          }
        ]
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

      sql                = null
      promql             = null
      promql_multi_alert = false
      promql_condition   = null
      promql_warning     = null
      threshold          = 3
      silence            = 60

      fingerprint = [
        "k8s_namespace_name",
        "k8s_pod_name",
      ]
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

      conditions = jsonencode({
        and = [
          {
            column      = "body"
            ignore_case = true
            operator    = "Contains"
            value       = "evict"
          }
        ]
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

      sql                = null
      promql             = null
      promql_multi_alert = false
      promql_condition   = null
      promql_warning     = null
      threshold          = 10
      silence            = 60

      fingerprint = [
        "k8s_namespace_name",
        "k8s_pod_name",
      ]
    }

    # --------------------------------------------------------------------------
    # INC-014 — Resource quota exceeded (resource_quota)
    # --------------------------------------------------------------------------
    INC-014 = {
      name        = "ResourceQuotaExceeded"
      folder      = "reliability"
      description = "INC-014: Deployment scaled beyond namespace ResourceQuota; pods stuck Pending"
      stream_type = "logs"
      stream_name = "app_logs"
      enabled     = true
      query_type  = "custom"

      conditions = jsonencode({
        and = [
          {
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
          }
        ]
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

      sql                = null
      promql             = null
      promql_multi_alert = false
      promql_condition   = null
      promql_warning     = null
      threshold          = 3
      silence            = 60

      fingerprint = [
        "k8s_namespace_name",
      ]
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

  destinations = [
    openobserve_alert_destination.autosre_webhook.name
  ]

  query_condition {
    type                 = each.value.query_type
    sql                  = each.value.sql
    promql               = each.value.promql
    conditions           = each.value.conditions
    promql_multi_alert   = each.value.promql_multi_alert
    promql_warning_value = each.value.promql_warning

    dynamic "promql_condition" {
      for_each = each.value.promql_condition == null ? [] : [each.value.promql_condition]

      content {
        column      = promql_condition.value.column
        operator    = promql_condition.value.operator
        value       = promql_condition.value.value
        ignore_case = promql_condition.value.ignore_case
      }
    }

    dynamic "aggregation" {
      for_each = each.value.aggregation == null ? [] : [each.value.aggregation]

      content {
        group_by      = aggregation.value.group_by
        function      = aggregation.value.function
        multi_alert   = aggregation.value.multi_alert
        warning_value = aggregation.value.warning_value

        dynamic "having" {
          for_each = aggregation.value.having == null ? [] : [aggregation.value.having]

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
    period     = 5
    frequency  = 5
    silence    = each.value.silence
    align_time = true

    operator  = each.value.promql_multi_alert || try(each.value.aggregation.multi_alert, false) ? null : ">="
    threshold = each.value.promql_multi_alert || try(each.value.aggregation.multi_alert, false) ? null : each.value.threshold
  }

  dynamic "deduplication" {
    for_each = [1]

    content {
      enabled             = true
      time_window_minutes = 30
      fingerprint_fields  = each.value.fingerprint
    }
  }

  depends_on = [
    openobserve_alert_destination.autosre_webhook,
    openobserve_folder.reliability,
    openobserve_folder.safety,
  ]
}
