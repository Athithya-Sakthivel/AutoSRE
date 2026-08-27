# ==============================================================================
# environments/staging.tfvars
#
# Only infrastructure values remain.  The serving app and training job are
# created by run.sh with sensible defaults (image, CPU, memory, replicas).
# ==============================================================================

alert_email_address = "athithya651@gmail.com"

tags = {
  app     = "serverless-mlops"
  owner   = "athithya"
  env     = "staging"
  project = "serverless-mlops"
}

environment = "staging"

storage_container_names   = ["raw", "clean", "models", "logs"]
shared_access_key_enabled = true # required to avoid premature validations


enable_request_failures_alert    = true
enable_slow_requests_alert       = false
enable_exceptions_alert          = false
enable_validation_failures_alert = true