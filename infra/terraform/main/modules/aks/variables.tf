# ============================================================================
# modules/aks/variables.tf - Input variables for the AKS module
# ============================================================================

variable "resource_group_name" {
  description = "Name of the resource group where AKS will be created."
  type        = string
}

variable "location" {
  description = "Azure region for AKS resources."
  type        = string
  default     = "centralindia"
}

variable "cluster_name" {
  description = "Name of the AKS cluster. Must also be valid as an AKS DNS prefix."
  type        = string

  validation {
    condition = can(
      regex(
        "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,52}[A-Za-z0-9])?$",
        var.cluster_name
      )
    )
    error_message = "cluster_name must contain only letters, numbers, and hyphens, start and end with a letter or number, and be 1-54 characters long."
  }
}

variable "kubernetes_version" {
  description = "AKS Kubernetes minor version. Override this for a version available in the target Azure region."
  type        = string
  default     = "1.36"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$", var.kubernetes_version))
    error_message = "kubernetes_version must be a valid Kubernetes version such as 1.36 or 1.36.3."
  }
}

variable "vm_size" {
  description = "VM size for the default system node pool. The default is a 4-vCPU size suitable for a 6-vCPU quota."
  type        = string
  default     = "Standard_D4s_v4"
}

variable "node_count" {
  description = "Number of nodes in the default system node pool. This module intentionally supports exactly one node because of the stated vCPU quota constraint."
  type        = number
  default     = 1

  validation {
    condition     = var.node_count == 1
    error_message = "node_count must be exactly 1 for this quota-optimized single-node module."
  }
}

variable "os_disk_size_gb" {
  description = "OS disk size in GB for nodes."
  type        = number
  default     = 50

  validation {
    condition     = var.os_disk_size_gb >= 30
    error_message = "os_disk_size_gb must be at least 30 GB."
  }
}

variable "aks_subnet_id" {
  description = "Resource ID of the subnet used by the AKS node pool. The subnet must have the user-assigned NAT Gateway attached before AKS creation."
  type        = string
}

variable "acr_id" {
  description = "Resource ID of the Azure Container Registry for the kubelet AcrPull role assignment."
  type        = string
}

variable "service_cidr" {
  description = "Kubernetes service CIDR. Must not overlap the VNet, AKS subnet, pod CIDR, peered networks, or on-premises networks."
  type        = string
  default     = "10.240.0.0/16"
}

variable "dns_service_ip" {
  description = "Kubernetes DNS service IP. Must be inside service_cidr and must not be the first IP in the service CIDR."
  type        = string
  default     = "10.240.0.10"
}

variable "pod_cidr" {
  description = "Pod CIDR for Azure CNI Overlay. Must not overlap the VNet, AKS subnet, service CIDR, peered networks, or on-premises networks."
  type        = string
  default     = "10.244.0.0/16"
}

variable "authorized_ip_ranges" {
  description = "Optional public CIDR ranges allowed to access the AKS API server. Leave empty to leave the public API server unrestricted by authorized IP ranges."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Common tags to apply to all resources."
  type        = map(string)
  default     = {}
}
