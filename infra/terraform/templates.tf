resource "openobserve_alert_template" "autosre_webhook" {
  name = "autosre-agent"
  type = "http"

  body = jsonencode({
    alert_name  = "{alert_name}"
    alert_url   = "{alert_url}"
    ended_at    = "{alert_end_time}"
    org_name    = "{org_name}"
    rows        = "{rows}"
    started_at  = "{alert_start_time}"
    stream_name = "{stream_name}"
  })
}
