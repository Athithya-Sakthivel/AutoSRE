# ------------------------------------------------------------------------------
# prod.tfvars – non‑sensitive values for the production environment
# ------------------------------------------------------------------------------

environment = "prod"
location    = "eastus"

resource_group_name = "rg-agentic-sre-prod"

container_app_environment_name = "cae-prod"
key_vault_name                 = "kv-agentic-prod"
cosmosdb_account_name          = "cosmos-agentic-prod"
acr_name                       = "acragenticprod"
log_analytics_workspace_name   = "law-agentic-prod"
application_insights_name      = "appi-agentic-prod"

cosmosdb_offer_type          = "Standard" # provisioned throughput for guaranteed performance
cosmosdb_enable_free_tier    = false
cosmosdb_throughput          = 1000 # RU/s per container (autoscale enabled)
acr_sku                      = "Standard"
log_analytics_retention_days = 30

container_apps = {
  target-system = {
    cpu              = 0.25
    memory           = "0.5Gi"
    min_replicas     = 1
    max_replicas     = 3
    target_port      = 8000
    external_ingress = true
    image            = "ghcr.io/athithya-sakthivel/target-system:latest"
    environment_variables = {
      LOG_LEVEL = "warn"
    }
  }
  mcp-tools = {
    cpu              = 0.25
    memory           = "0.5Gi"
    min_replicas     = 1
    max_replicas     = 3
    target_port      = 8000
    external_ingress = true
    image            = "ghcr.io/athithya-sakthivel/mcp-tools:latest"
    environment_variables = {
      LOG_LEVEL = "warn"
    }
  }
  agent-brain = {
    cpu              = 0.5
    memory           = "1Gi"
    min_replicas     = 1
    max_replicas     = 3
    target_port      = 8000
    external_ingress = true
    image            = "ghcr.io/athithya-sakthivel/agent-brain:latest"
    environment_variables = {
      LOG_LEVEL = "warn"
    }
  }
}

tags = {
  environment = "prod"
  project     = "agentic-sre"
  cost-center = "ai-platform-prod"
}