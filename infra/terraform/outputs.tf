# Terraform/OpenTofu outputs describe only resources that Terraform actually
# owns. OpenObserve telemetry streams are intentionally absent because their
# lifecycle belongs to scripts/staging/openobserve.sh.

output "alert_count" {
  description = "Total number of OpenObserve alert rules managed by this stack"
  value       = length(openobserve_alert.incidents)
}

output "alert_counts_by_type" {
  description = "Number of managed alerts by OpenObserve query type"

  value = {
    custom = length({
      for k, v in local.alerts : k => v
      if v.query_type == "custom"
    })

    promql = length({
      for k, v in local.alerts : k => v
      if v.query_type == "promql"
    })

    sql = length({
      for k, v in local.alerts : k => v
      if v.query_type == "sql"
    })
  }
}

output "alert_ids" {
  description = "Map of AutoSRE incident ID to OpenObserve alert resource ID"

  value = {
    for k, v in openobserve_alert.incidents : k => v.id
  }
}

output "destination_name" {
  description = "OpenObserve alert destination name"
  value       = openobserve_alert_destination.autosre_webhook.name
}

output "template_name" {
  description = "OpenObserve alert template name"
  value       = openobserve_alert_template.autosre_webhook.name
}
