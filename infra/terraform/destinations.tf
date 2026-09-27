# Webhook destination. All 12 alerts share this.
#
# Notes:
#   - `method` is lowercase per the schema enum: post | put | get
#   - `type` = "http" for webhooks (default is http)
#   - `template` binds the destination to the alert template defined in
#     templates.tf. Without it, O2 treats the destination as a pipeline
#     destination and rejects it as an alert target.

resource "openobserve_alert_destination" "autosre_webhook" {
  name     = "autosre-agent-webhook"
  type     = "http"
  url      = var.agent_webhook_url
  method   = "post"
  template = openobserve_alert_template.autosre_webhook.name

  headers = {
    "Content-Type" = "application/json"
  }
}
