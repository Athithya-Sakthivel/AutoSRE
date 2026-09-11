# ------------------------------------------------------------------------------
# staging.tfvars – only the variables needed for the state module
# ------------------------------------------------------------------------------

resource_group_name = "rg-agentic-sre-staging"
location            = "centralindia"

tags = {
  environment = "staging"
  project     = "agentic-sre"
}

cosmosdb_account_name     = "cosmos-agentic-staging"
cosmosdb_offer_type       = "Serverless" # This now works via capabilities
cosmosdb_enable_free_tier = true
cosmosdb_throughput       = 400

acr_name = "acragenticstaging"
acr_sku  = "Basic"