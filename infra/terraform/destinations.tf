# OpenObserve alert delivery destination.
#
# The destination is Terraform-managed. It points at the AutoSRE agent, while
# stream creation remains completely outside Terraform.

resource "openobserve_alert_destination" "autosre_webhook" {
  name     = "autosre-agent-webhook"
  type     = "http"
  url      = var.agent_webhook_url
  method   = "post"
  template = openobserve_alert_template.autosre_webhook.name

  headers = {
    "Content-Type" = "application/json"
  }

  depends_on = [
    openobserve_alert_template.autosre_webhook
  ]
}
