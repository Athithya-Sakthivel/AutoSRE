alert_email_address = "athithya651@gmail.com"

tags = {
  app     = "serverless-mlops"
  owner   = "athithya"
  env     = "prod"
  project = "serverless-mlops"
}

environment = "prod"

storage_container_names   = ["raw", "clean", "models", "logs"]
shared_access_key_enabled = true # required to avoid premature validations

aca_training_image = "busybox:1.36.1@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662"
aca_serving_image  = "mcr.microsoft.com/azuredocs/containerapps-helloworld@sha256:e9b3e7c34664c7cffd7144864b0e4eec369bfde80068f9095dc63b37058bec48"
aca_serve_port     = 80


serve_cpu          = 0.5
serve_memory       = "1Gi"
serve_min_replicas = 0
serve_max_replicas = 6

enable_request_failures_alert    = true
enable_slow_requests_alert       = true
enable_exceptions_alert          = true
enable_validation_failures_alert = true
