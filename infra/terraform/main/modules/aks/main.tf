# ============================================================================
# modules/aks/main.tf - AKS cluster, identity, networking, and RBAC
#
# Design:
#   - User-assigned control-plane managed identity.
#   - Azure CNI Overlay with Cilium eBPF dataplane/network policy.
#   - User-assigned NAT Gateway attached to the supplied AKS subnet.
#   - Azure Workload Identity with OIDC issuer enabled.
#   - AcrPull granted to the AKS kubelet identity at ACR scope.
# ============================================================================

# ----------------------------------------------------------------------------
# User-assigned managed identity for the AKS control plane
# ----------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "aks" {
  name                = "${var.cluster_name}-identity"
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = var.tags
}

resource "azurerm_role_assignment" "network_contributor" {
  scope                = var.aks_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  node_provisioning_profile {
    mode = "Manual" # Required in AzureRM 5.x
  }

  default_node_pool {
    name                 = "default"
    vm_size              = var.vm_size
    node_count           = var.node_count
    auto_scaling_enabled = false # Correct name in AzureRM 5.x
    os_disk_size_gb      = var.os_disk_size_gb
    os_sku               = "AzureLinux3"
    vnet_subnet_id       = var.aks_subnet_id
    # No node_taints, no node_labels (optional)
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    outbound_type       = "userAssignedNATGateway"
    load_balancer_sku   = "standard"
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
    pod_cidr            = var.pod_cidr
  }

  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  dynamic "api_server_access_profile" {
    for_each = length(var.authorized_ip_ranges) > 0 ? [true] : []

    content {
      authorized_ip_ranges = var.authorized_ip_ranges
    }
  }

  tags = var.tags

  depends_on = [
    azurerm_role_assignment.network_contributor
  ]
  lifecycle {
    ignore_changes = [
      kubernetes_version,   # Ignore minor version changes
    ]
  }
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}
