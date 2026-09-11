# ------------------------------------------------------------------------------
# Cosmos DB account – serverless or provisioned based on capabilities.
# ------------------------------------------------------------------------------
resource "azurerm_cosmosdb_account" "main" {
  name                = var.cosmosdb_account_name
  resource_group_name = var.resource_group_name
  location            = var.location
  offer_type          = "Standard" # Must be "Standard"
  kind                = "GlobalDocumentDB"

  free_tier_enabled          = var.cosmosdb_enable_free_tier
  analytical_storage_enabled = false

  # Enable serverless via capabilities
  capabilities {
    name = "EnableServerless"
  }

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
  }

  tags = var.tags
}

# ------------------------------------------------------------------------------
# SQL database – holds both checkpoints and rate‑limit collections.
# ------------------------------------------------------------------------------
resource "azurerm_cosmosdb_sql_database" "main" {
  name                = var.database_name
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name

  # For serverless, no throughput is set.
  # For standard provisioned, we set throughput or autoscale.
  throughput = var.cosmosdb_offer_type == "Standard" && var.cosmosdb_autoscale_max_throughput == null ? var.cosmosdb_throughput : null

  dynamic "autoscale_settings" {
    for_each = var.cosmosdb_offer_type == "Standard" && var.cosmosdb_autoscale_max_throughput != null ? [1] : []
    content {
      max_throughput = var.cosmosdb_autoscale_max_throughput
    }
  }

  depends_on = [azurerm_cosmosdb_account.main]
}

# ------------------------------------------------------------------------------
# Container for checkpoints.
# ------------------------------------------------------------------------------
resource "azurerm_cosmosdb_sql_container" "checkpoints" {
  name                = var.checkpoint_container_name
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.main.name

  partition_key_paths   = ["/id"]
  partition_key_version = 1

  throughput = var.cosmosdb_offer_type == "Standard" && var.cosmosdb_autoscale_max_throughput == null ? var.cosmosdb_throughput : null

  dynamic "autoscale_settings" {
    for_each = var.cosmosdb_offer_type == "Standard" && var.cosmosdb_autoscale_max_throughput != null ? [1] : []
    content {
      max_throughput = var.cosmosdb_autoscale_max_throughput
    }
  }

  indexing_policy {
    indexing_mode = "consistent"
    included_path {
      path = "/*"
    }
    excluded_path {
      path = "/\"_etag\"/?"
    }
  }

  depends_on = [azurerm_cosmosdb_sql_database.main]
}

# ------------------------------------------------------------------------------
# Container for rate‑limits.
# ------------------------------------------------------------------------------
resource "azurerm_cosmosdb_sql_container" "rate_limits" {
  name                = var.rate_limit_container_name
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.main.name

  partition_key_paths   = ["/resource_id"]
  partition_key_version = 1
  default_ttl           = var.rate_limit_default_ttl_seconds

  throughput = var.cosmosdb_offer_type == "Standard" && var.cosmosdb_autoscale_max_throughput == null ? var.cosmosdb_throughput : null

  dynamic "autoscale_settings" {
    for_each = var.cosmosdb_offer_type == "Standard" && var.cosmosdb_autoscale_max_throughput != null ? [1] : []
    content {
      max_throughput = var.cosmosdb_autoscale_max_throughput
    }
  }

  indexing_policy {
    indexing_mode = "consistent"
    included_path {
      path = "/*"
    }
    excluded_path {
      path = "/\"_etag\"/?"
    }
  }

  depends_on = [azurerm_cosmosdb_sql_database.main]
}