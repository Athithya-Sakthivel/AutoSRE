# ==============================================================================
# locals.tf – Derived names and common tags
# ==============================================================================

locals {
  project_name = "task-api"
  project_abbr = "taskapi"
  env_abbr     = var.environment == "staging" ? "stg" : "prod"
  sub_suffix   = substr(var.subscription_id, length(var.subscription_id) - 6, 6)

  common_tags = merge(
    {
      project     = local.project_name
      environment = var.environment
      managed_by  = "opentofu"
      owner       = var.owner # injected via TF_VAR_owner
    },
    var.tags
  )

  # Resource group
  resource_group_name = "rg-${local.project_abbr}-${local.env_abbr}"

  bootstrap_key_vault_name = "kv-azdo-bootstrap-${local.sub_suffix}"
  bootstrap_state_rg       = "rg-sm-state-${local.sub_suffix}"

  # Networking
  vnet_name                      = "vnet-${local.project_abbr}-${local.env_abbr}"
  vnet_address_space             = ["10.1.0.0/16"]
  aks_subnet_name                = "snet-aks-${local.env_abbr}"
  aks_subnet_address_prefix      = "10.1.1.0/24"
  pe_subnet_name                 = "snet-pe-${local.env_abbr}"
  pe_subnet_address_prefix       = "10.1.2.0/24"
  reserved_subnet_name           = "snet-reserved-${local.env_abbr}"
  reserved_subnet_address_prefix = "10.1.3.0/24"
  nat_gateway_name               = "nat-${local.project_abbr}-${local.env_abbr}"
  nat_public_ip_name             = "pip-${local.project_abbr}-${local.env_abbr}"
  aks_nsg_name                   = "nsg-aks-${local.env_abbr}"
  pe_nsg_name                    = "nsg-pe-${local.env_abbr}"
  private_dns_zone_name          = "privatelink.postgres.database.azure.com"
  private_dns_zone_link_name     = "postgres-vnet-link"

  # AKS
  aks_cluster_name = "aks-${local.project_abbr}-${local.env_abbr}-${local.sub_suffix}"

  # PostgreSQL
  postgresql_server_name = "psql-${local.project_abbr}-${local.env_abbr}-${local.sub_suffix}"

  # ACR
  acr_name = "acr${local.project_abbr}${local.env_abbr}${local.sub_suffix}"

  # Observability
  log_analytics_workspace_name = "law-${local.project_abbr}-${local.env_abbr}"
  application_insights_name    = "appi-${local.project_abbr}-${local.env_abbr}"
}
