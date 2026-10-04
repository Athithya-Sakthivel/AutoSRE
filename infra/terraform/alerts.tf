# ==============================================================================
# alerts.tf — AutoSRE OpenObserve alert rules
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
    # INC-001 — PostgreSQL error volume
    # --------------------------------------------------------------------------
    INC-001 = {
      name        = "DatabaseConnectionPoolExhausted"
      folder      = "reliability"
      description = "INC-001: PostgreSQL error volume"
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

      # This is the aggregate critical threshold.
      # It belongs in aggregation.having, NOT trigger_condition.threshold.
      threshold = 18

      silence = 30

      fingerprint = [
        "k8s_namespace_name",
        "k8s_pod_name",
      ]
    }

    # --------------------------------------------------------------------------
    # INC-002 — API gateway CPU utilization
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

      # The PromQL critical value lives in promql_condition.
      # Do NOT put 90 into trigger_condition.threshold because with
      # promql_multi_alert that would become a group-count threshold.
      threshold = null

      silence = 30

      fingerprint = [
        "k8s_namespace_name",
        "k8s_pod_name",
      ]
    }

    # --------------------------------------------------------------------------
    # INC-003 — Idle-in-transaction PostgreSQL backlog
    # --------------------------------------------------------------------------
    INC-003 = {
      name        = "IdleInTransactionBacklog"
      folder      = "reliability"
      description = "INC-003: idle-in-transaction PostgreSQL sessions"
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
    # INC-004 — Cache poison / JSON decoding failures
    # --------------------------------------------------------------------------
    INC-004 = {
      name        = "CachePoisonKey"
      folder      = "reliability"
      description = "INC-004: JSONDecodeError spikes"
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
    # INC-005 — Valkey consumer backlog
    # --------------------------------------------------------------------------
    INC-005 = {
      name        = "ConsumerLagSpike"
      folder      = "reliability"
      description = "INC-005: Valkey pending-message volume"
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
    # INC-006 — API gateway memory utilization
    # --------------------------------------------------------------------------
    INC-006 = {
      name        = "ApiGatewayMemoryPressure"
      folder      = "reliability"
      description = "INC-006: api-gateway memory utilization above 90% of pod limits"
      stream_type = "metrics"
      stream_name = "k8s_pod_memory_limit_utilization"
      enabled     = true
      query_type  = "promql"

      conditions  = null
      aggregation = null
      sql         = null

      promql = "k8s_pod_memory_limit_utilization{k8s_namespace_name=\"rivulet\",k8s_pod_name=~\"api-gateway.*\"}"

      promql_multi_alert = true

      promql_condition = {
        column      = "value"
        ignore_case = false
        operator    = ">="
        value       = "90"
      }

      promql_warning = 80
      threshold     = null
      silence       = 60

      fingerprint = [
        "k8s_namespace_name",
        "k8s_pod_name",
      ]
    }

    # --------------------------------------------------------------------------
    # INC-007 — Upstream timeout cascade
    # --------------------------------------------------------------------------
    INC-007 = {
      name        = "UpstreamTimeoutCascade"
      folder      = "reliability"
      description = "INC-007: frontend upstream timeout volume"
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
            value       = "upstream timeout"
          }
        ]
      })

      aggregation = {
        group_by      = ["service", "upstream"]
        function      = "count"
        multi_alert   = true
        warning_value = 25

        having = {
          column   = "_timestamp"
          operator = ">="
          value    = "50"
        }
      }

      sql                = null
      promql             = null
      promql_multi_alert = false
      promql_condition   = null
      promql_warning     = null
      threshold          = 50
      silence            = 30

      fingerprint = [
        "service",
        "upstream",
      ]
    }

    # --------------------------------------------------------------------------
    # INC-008 — Ingestion worker memory utilization
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
      threshold     = null
      silence       = 60

      fingerprint = [
        "k8s_namespace_name",
        "k8s_pod_name",
      ]
    }

    # --------------------------------------------------------------------------
    # INC-009 — Ingestion worker CPU utilization
    # --------------------------------------------------------------------------
    INC-009 = {
      name        = "IngestionWorkerCPUPressure"
      folder      = "reliability"
      description = "INC-009: ingestion-worker CPU utilization above 90% of pod CPU limits"
      stream_type = "metrics"
      stream_name = "k8s_pod_cpu_limit_utilization"
      enabled     = true
      query_type  = "promql"

      conditions  = null
      aggregation = null
      sql         = null

      promql = "k8s_pod_cpu_limit_utilization{k8s_namespace_name=\"rivulet\",k8s_pod_name=~\"ingestion-worker.*\"}"

      promql_multi_alert = true

      promql_condition = {
        column      = "value"
        ignore_case = false
        operator    = ">="
        value       = "90"
      }

      promql_warning = 80
      threshold     = null
      silence       = 30

      fingerprint = [
        "k8s_namespace_name",
        "k8s_pod_name",
      ]
    }

    # --------------------------------------------------------------------------
    # INC-010 — Deduplication safety canary
    #
    # This alert is deliberately disabled.
    #
    # IMPORTANT:
    # fingerprint is intentionally null rather than [].
    #
    # An empty Set is materialized by Terraform/OpenTofu as an actual empty
    # cty.Set, while OpenObserve returns null when fingerprint_fields are
    # omitted. That mismatch caused the provider's:
    #
    #   Provider produced inconsistent result after apply
    #
    # error.
    #
    # With null, the deduplication block omits fingerprint_fields and lets
    # OpenObserve infer the fingerprint.
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
    # INC-011 — Namespace deletion safety canary
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
    # INC-012 — Cascading failure across critical services
    # --------------------------------------------------------------------------
    INC-012 = {
      name        = "CascadingFailureAcrossServices"
      folder      = "reliability"
      description = "INC-012: elevated error volume in api-gateway or ingestion-worker"
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
            value       = "error"
          },
          {
            or = [
              {
                column      = "k8s_pod_name"
                ignore_case = false
                operator    = "Contains"
                value       = "api-gateway"
              },
              {
                column      = "k8s_pod_name"
                ignore_case = false
                operator    = "Contains"
                value       = "ingestion-worker"
              }
            ]
          }
        ]
      })

      aggregation = {
        group_by      = ["k8s_namespace_name", "k8s_pod_name"]
        function      = "count"
        multi_alert   = true
        warning_value = 10

        having = {
          column   = "_timestamp"
          operator = ">="
          value    = "20"
        }
      }

      sql                = null
      promql             = null
      promql_multi_alert = false
      promql_condition   = null
      promql_warning     = null
      threshold          = 20
      silence            = 60

      fingerprint = [
        "k8s_namespace_name",
        "k8s_pod_name",
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

  # These streams are intentionally literal strings.
  # Terraform/OpenTofu does not manage stream lifecycle.
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
    period    = 5
    frequency = 5
    silence   = each.value.silence
    align_time = true

    # OpenObserve interprets trigger_condition.threshold as a group-count
    # threshold when per-group alerting is enabled.
    #
    # For multi-alerts:
    #   threshold = null
    #   operator  = null
    #
    # For ordinary/single-result alerts:
    #   threshold = the normal trigger threshold
    #   operator  = >=
    #
    # This prevents:
    #
    #   per-group alerting + group-count threshold
    #
    # which the OpenObserve API explicitly rejects.
    operator  = each.value.promql_multi_alert || try(each.value.aggregation.multi_alert, false) ? null : ">="
    threshold = each.value.promql_multi_alert || try(each.value.aggregation.multi_alert, false) ? null : each.value.threshold
  }

  # Deduplication is always enabled.
  #
  # fingerprint_fields is emitted only when an explicit fingerprint is
  # configured. For INC-010 and INC-011 the server must infer it.
  dynamic "deduplication" {
    for_each = [1]

    content {
      enabled             = true
      time_window_minutes = 30

      # null => attribute omitted from the request.
      # This is deliberate: [] causes the provider to hold an empty cty.Set,
      # while the server reads the omitted value back as null.
      fingerprint_fields = each.value.fingerprint
    }
  }

  depends_on = [
    openobserve_alert_destination.autosre_webhook,
    openobserve_folder.reliability,
    openobserve_folder.safety,
  ]
}
