# ==============================================================================
# outputs.tf – Root outputs
# ==============================================================================

# ------------------------------------------------------------------------------
# Resource Group
# ------------------------------------------------------------------------------

output "resource_group_name" {
  description = "Resource group containing all platform resources."
  value       = module.state.resource_group_name
}

output "resource_group_id" {
  description = "ARM resource ID of the resource group."
  value       = module.state.resource_group_id
}

# ------------------------------------------------------------------------------
# Azure Container Registry
# ------------------------------------------------------------------------------

output "acr_name" {
  description = "Name of the Azure Container Registry."
  value       = module.state.acr_name
}

output "acr_id" {
  description = "ARM resource ID of the Azure Container Registry."
  value       = module.state.acr_id
}

output "acr_login_server" {
  description = "ACR login server URL used by Docker and Kubernetes."
  value       = module.state.acr_login_server
}

# ------------------------------------------------------------------------------
# AKS Cluster
# ------------------------------------------------------------------------------

output "aks_cluster_id" {
  description = "AKS cluster resource ID."
  value       = module.aks.cluster_id
}

output "aks_cluster_name" {
  description = "AKS cluster name."
  value       = module.aks.cluster_name
}

output "aks_oidc_issuer_url" {
  description = "OIDC issuer URL for workload identity federation."
  value       = module.aks.oidc_issuer_url
}

output "aks_kubelet_identity_object_id" {
  description = "Object ID of the AKS kubelet managed identity (used for ACR pull)."
  value       = module.aks.kubelet_identity_object_id
}

output "aks_node_resource_group" {
  description = "Resource group where AKS node resources are placed (VMSS, disks, NICs)."
  value       = module.aks.node_resource_group
}

# ------------------------------------------------------------------------------
# Networking
# ------------------------------------------------------------------------------

output "vnet_id" {
  description = "ARM resource ID of the virtual network."
  value       = module.networking.vnet_id
}

output "vnet_name" {
  description = "Name of the virtual network."
  value       = module.networking.vnet_name
}

output "aks_subnet_id" {
  description = "ID of the AKS subnet."
  value       = module.networking.aks_subnet_id
}

output "private_endpoint_subnet_id" {
  description = "ID of the private endpoint subnet."
  value       = module.networking.pe_subnet_id
}

output "nat_public_ip" {
  description = "Public IP address of the NAT Gateway (for outbound allow-listing)."
  value       = module.networking.nat_public_ip
}

output "private_dns_zone_id" {
  description = "ID of the PostgreSQL private DNS zone."
  value       = module.networking.private_dns_zone_id
}

# ------------------------------------------------------------------------------
# PostgreSQL
# ------------------------------------------------------------------------------

output "postgresql_server_id" {
  description = "ARM resource ID of the PostgreSQL Flexible Server."
  value       = module.postgresql.server_id
}

output "postgresql_server_name" {
  description = "Name of the PostgreSQL Flexible Server."
  value       = module.postgresql.server_name
}

output "postgresql_server_fqdn" {
  description = "Fully qualified domain name of the PostgreSQL server."
  value       = module.postgresql.server_fqdn
}

output "postgresql_database_name" {
  description = "Name of the application database."
  value       = module.postgresql.database_name
}

output "postgresql_private_endpoint_id" {
  description = "ARM resource ID of the PostgreSQL private endpoint."
  value       = module.postgresql.private_endpoint_id
}

output "postgresql_private_endpoint_ip" {
  description = "Private IP address of the PostgreSQL private endpoint."
  value       = module.postgresql.private_endpoint_private_ip
}

# ------------------------------------------------------------------------------
# Observability
# ------------------------------------------------------------------------------

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace ARM resource ID."
  value       = module.observability.log_analytics_workspace_id
}

output "log_analytics_workspace_name" {
  description = "Log Analytics workspace name."
  value       = module.observability.log_analytics_workspace_name
}

output "log_analytics_workspace_customer_id" {
  description = "Log Analytics workspace/customer GUID."
  value       = module.observability.log_analytics_workspace_customer_id
}

output "application_insights_id" {
  description = "Application Insights ARM resource ID."
  value       = module.observability.application_insights_id
}

output "application_insights_name" {
  description = "Application Insights component name."
  value       = module.observability.application_insights_name
}

output "application_insights_app_id" {
  description = "Application Insights App ID."
  value       = module.observability.application_insights_app_id
}

output "application_insights_connection_string" {
  description = "Application Insights connection string."
  value       = module.observability.application_insights_connection_string
  sensitive   = true
}

output "observability_action_group_id" {
  description = "Azure Monitor action group ARM resource ID."
  value       = module.observability.action_group_id
}

output "observability_workbook_id" {
  description = "Azure Monitor Workbook ARM resource ID."
  value       = module.observability.workbook_id
}

# ------------------------------------------------------------------------------
# Azure DevOps
# ------------------------------------------------------------------------------

output "ci_backend_pipeline_id" {
  description = "ID of the backend CI pipeline."
  value       = module.azure_devops.ci_backend_pipeline_id
}

output "ci_frontend_pipeline_id" {
  description = "ID of the frontend CI pipeline."
  value       = module.azure_devops.ci_frontend_pipeline_id
}

output "cd_backend_pipeline_id" {
  description = "ID of the backend CD pipeline."
  value       = module.azure_devops.cd_backend_pipeline_id
}

output "cd_frontend_pipeline_id" {
  description = "ID of the frontend CD pipeline."
  value       = module.azure_devops.cd_frontend_pipeline_id
}
