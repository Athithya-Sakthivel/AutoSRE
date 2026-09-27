# Alert template. Per the v1.4.0 docs: "Required for a destination to be
# usable by alerts." The template defines the JSON body that O2 posts to
# the destination URL.
#
# Supported placeholders (documented for v1.4.0):
#   {alert_name}        Name of the alert
#   {stream_name}       Target stream
#   {org_name}          Organization
#   {alert_start_time}  When the alert condition first held
#   {alert_end_time}    When the alert condition stopped holding
#   {alert_url}         Deep link into the O2 UI
#   {rows}              JSON array of matching rows (if configured)

resource "openobserve_alert_template" "autosre_webhook" {
  name = "autosre-agent"
  type = "http"

  body = jsonencode({
    alert_name  = "{alert_name}"
    stream_name = "{stream_name}"
    org_name    = "{org_name}"
    started_at  = "{alert_start_time}"
    ended_at    = "{alert_end_time}"
    alert_url   = "{alert_url}"
    rows        = "{rows}"
  })
}
