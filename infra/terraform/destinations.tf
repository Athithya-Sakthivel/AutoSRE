# OpenObserve alert delivery destination.
#
# The X-Source header identifies O2-originated webhooks so the agent can
# skip HMAC verification (O2 cannot compute HMAC-SHA256 on rendered bodies).
# The agent trusts webhooks with X-Source: openobserve when they arrive
# from the cluster network.

resource "openobserve_alert_destination" "autosre_webhook" {
  name     = "autosre-agent-webhook"
  type     = "http"
  url      = var.agent_webhook_url
  method   = "post"
  template = openobserve_alert_template.autosre_webhook.name

  headers = {
    "Content-Type" = "application/json"
    "X-Source"     = "openobserve"
  }

  depends_on = [
    openobserve_alert_template.autosre_webhook
  ]
}
