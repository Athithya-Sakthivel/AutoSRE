variable "resource_group_name" {
  description = "Resource group for AKS"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "centralindia"
}

variable "cluster_name" {
  description = "AKS cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.36"
}

variable "vm_size" {
  description = "VM size"
  type        = string
  default     = "Standard_D4s_v4"
}

variable "node_count" {
  description = "Number of nodes"
  type        = number
  default     = 1
}

variable "os_disk_size_gb" {
  description = "OS disk size"
  type        = number
  default     = 50
}

variable "aks_subnet_id" {
  description = "Subnet ID for AKS"
  type        = string
}

variable "acr_id" {
  description = "ACR resource ID"
  type        = string
}

variable "service_cidr" {
  description = "Service CIDR"
  type        = string
  default     = "10.240.0.0/16"
}

variable "dns_service_ip" {
  description = "DNS service IP"
  type        = string
  default     = "10.240.0.10"
}

variable "pod_cidr" {
  description = "Pod CIDR"
  type        = string
  default     = "10.244.0.0/16"
}

variable "tags" {
  description = "Tags"
  type        = map(string)
  default     = {}
}
