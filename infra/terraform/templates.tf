resource "openobserve_alert_template" "autosre_webhook" {
  name = "autosre-agent"
  type = "http"

  body = jsonencode({
    alert_name  = "{alert_name}"
    alert_url   = "{alert_url}"
    stream_name = "{stream_name}"
    stream_type = "{stream_type}"
    org_name    = "{org_name}"
    started_at  = "{alert_start_time}"
    ended_at    = "{alert_end_time}"
    rows        = "{rows}"
    alert_count = "{alert_count}"
    alert_agg_value = "{alert_agg_value}"
    alert_threshold = "{alert_threshold}"
    alert_operator  = "{alert_operator}"
  })
}
