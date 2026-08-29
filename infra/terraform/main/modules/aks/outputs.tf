# ============================================================================
# modules/aks/outputs.tf - Output values for the AKS module
# ============================================================================

output "cluster_id" {
  description = "ARM resource ID of the AKS cluster."
  value       = azurerm_kubernetes_cluster.this.id
}

output "cluster_name" {
  description = "Name of the AKS cluster."
  value       = azurerm_kubernetes_cluster.this.name
}

output "cluster_identity_principal_id" {
  description = "Principal ID of the AKS control-plane user-assigned managed identity."
  value       = azurerm_user_assigned_identity.aks.principal_id
}

output "kubelet_identity_object_id" {
  description = "Object ID of the kubelet managed identity used for AcrPull."
  value       = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

output "node_resource_group" {
  description = "Name of the resource group where AKS node resources are placed."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL of the AKS cluster for workload identity federation."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "kube_config" {
  description = "Raw kubeconfig for the AKS cluster. This value is sensitive and is persisted in state."
  value       = azurerm_kubernetes_cluster.this.kube_config_raw
  sensitive   = true
}
