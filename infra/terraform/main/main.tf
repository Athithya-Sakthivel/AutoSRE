# ==============================================================================
# main.tf – Root module orchestration
# ==============================================================================

# ------------------------------------------------------------------------------
# Fetch secrets from bootstrap Key Vault
# ------------------------------------------------------------------------------
data "azurerm_key_vault" "bootstrap" {
  name                = local.bootstrap_key_vault_name
  resource_group_name = local.bootstrap_state_rg
}

data "azurerm_key_vault_secret" "database_password" {
  name         = "DatabasePassword"
  key_vault_id = data.azurerm_key_vault.bootstrap.id
}

module "state" {
  source = "./modules/state"

  resource_group_name = local.resource_group_name
  location            = var.location
  acr_name            = local.acr_name
  acr_sku             = var.acr_sku
  acr_admin_enabled   = false
  tags                = local.common_tags
}

module "networking" {
  source = "./modules/networking"

  resource_group_name            = module.state.resource_group_name
  location                       = var.location
  vnet_name                      = local.vnet_name
  vnet_address_space             = local.vnet_address_space
  aks_subnet_name                = local.aks_subnet_name
  aks_subnet_address_prefix      = local.aks_subnet_address_prefix
  pe_subnet_name                 = local.pe_subnet_name
  pe_subnet_address_prefix       = local.pe_subnet_address_prefix
  reserved_subnet_name           = local.reserved_subnet_name
  reserved_subnet_address_prefix = local.reserved_subnet_address_prefix
  nat_gateway_name               = local.nat_gateway_name
  nat_public_ip_name             = local.nat_public_ip_name
  aks_nsg_name                   = local.aks_nsg_name
  pe_nsg_name                    = local.pe_nsg_name
  private_dns_zone_name          = local.private_dns_zone_name
  private_dns_zone_link_name     = local.private_dns_zone_link_name
  tags                           = local.common_tags
}

module "aks" {
  source = "./modules/aks"

  resource_group_name = module.state.resource_group_name
  location            = var.location
  cluster_name        = local.aks_cluster_name
  kubernetes_version  = var.aks_kubernetes_version
  vm_size             = var.aks_vm_size
  node_count          = var.aks_node_count
  os_disk_size_gb     = var.aks_os_disk_size_gb
  aks_subnet_id       = module.networking.aks_subnet_id
  acr_id              = module.state.acr_id
  service_cidr        = var.aks_service_cidr
  dns_service_ip      = var.aks_dns_service_ip
  pod_cidr            = var.aks_pod_cidr
  tags                = local.common_tags
}

module "postgresql" {
  source = "./modules/postgresql"

  resource_group_name        = module.state.resource_group_name
  location                   = var.location
  server_name                = local.postgresql_server_name
  postgresql_version         = var.postgresql_version
  sku_name                   = var.postgresql_sku_name
  storage_mb                 = var.postgresql_storage_mb
  backup_retention_days      = var.postgresql_backup_retention_days
  administrator_login        = var.postgresql_administrator_login
  administrator_password     = data.azurerm_key_vault_secret.database_password.value
  database_name              = var.postgresql_database_name
  private_endpoint_subnet_id = module.networking.pe_subnet_id
  private_dns_zone_id        = module.networking.private_dns_zone_id
  tags                       = local.common_tags
}

module "observability" {
  source = "./modules/observability"

  resource_group_name = module.state.resource_group_name
  location            = var.location
  environment         = var.environment

  log_analytics_workspace_name = local.log_analytics_workspace_name
  log_analytics_retention_days = var.log_analytics_retention_days

  application_insights_name = local.application_insights_name

  alert_email_address = var.alert_email_address

  aks_cluster_id = module.aks.cluster_id

  postgresql_server_id = module.postgresql.server_id

  enable_cpu_alert                         = var.enable_cpu_alert
  enable_memory_alert                      = var.enable_memory_alert
  enable_pod_restarts_alert                = var.enable_pod_restarts_alert
  enable_failed_requests_alert             = var.enable_failed_requests_alert
  enable_postgres_storage_alert            = var.enable_postgres_storage_alert
  application_insights_sampling_percentage = var.application_insights_sampling_percentage
  tags                                     = local.common_tags
}

module "azure_devops" {
  source = "./modules/azure_devops"

  project_name                    = var.ado_project_name
  github_service_connection_name  = var.ado_github_service_connection_name
  azure_service_connection_name   = var.ado_azure_service_connection_name
  github_owner                    = var.github_owner
  github_repo                     = var.github_repo
  branch                          = var.branch
  terraform_vars_group_name       = var.terraform_vars_group_name
  authorize_variable_group_for_ci = var.authorize_variable_group_for_ci
}
