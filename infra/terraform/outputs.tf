output "alert_count" {
  description = "Number of OpenObserve alert rules declared by this stack"
  value       = length(openobserve_alert.incidents)
}

output "alert_ids" {
  description = "Map of incident ID to OpenObserve alert resource ID"
  value = {
    for k, v in openobserve_alert.incidents : k => v.id
  }
}

output "destination_name" {
  description = "OpenObserve alert destination"
  value       = openobserve_alert_destination.autosre_webhook.name
}

output "template_name" {
  description = "OpenObserve alert template"
  value       = openobserve_alert_template.autosre_webhook.name
}
