# =============================================================================
# AutoSRE — Terraform Provider Configuration
# =============================================================================
#
# Providers:
#   - kubernetes: Deploys Rivulet stack + AutoSRE agent to Kind cluster
#   - helm: Deploys OpenObserve via Helm chart (alternative path)
#   - openobserve: Manages O2 streams, alerts, folders, destinations
#
# Authentication:
#   - kubernetes: Uses local kubeconfig (~/.kube/config) or KUBE_CONFIG_PATH
#   - openobserve: Credentials from env vars or tfvars (NEVER commit secrets)
#
# Usage:
#   cd infra/terraform
#   export TF_VAR_o2_password="your-secure-password"
#   terraform init
#   terraform plan
#   terraform apply
# =============================================================================

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.32"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
    openobserve = {
      source  = "openobserve/openobserve"
      version = "~> 1.4.1"
    }
  }

  # Optional: remote state backend for team workflows
  # backend "s3" {
  #   bucket = "autosre-tf-state"
  #   key    = "infra/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

# -----------------------------------------------------------------------------
# Kubernetes Provider
# -----------------------------------------------------------------------------
# Uses the current kubectl context. For Kind cluster, ensure:
#   kind create cluster --name autosre
#   export KUBE_CONFIG_PATH=~/.kube/config

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

# -----------------------------------------------------------------------------
# Helm Provider
# -----------------------------------------------------------------------------
provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
  }
}

# -----------------------------------------------------------------------------
# OpenObserve Provider
# -----------------------------------------------------------------------------
# Authenticates via Basic Auth against the O2 HTTP API.
# Endpoint is the in-cluster service URL (via port-forward for local dev).
#
# For local dev:
#   kubectl port-forward -n openobserve svc/openobserve 5080:5080
#   export TF_VAR_o2_endpoint="http://localhost:5080"
#   export TF_VAR_o2_email="root@example.com"
#   export TF_VAR_o2_password="your-password"

provider "openobserve" {
  endpoint         = var.o2_endpoint
  username         = var.o2_email
  password         = var.o2_password
  organization     = var.o2_organization
  insecure         = var.o2_insecure
  version          = "v1"
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Kubernetes context to use (e.g., kind-autosre)"
  type        = string
  default     = null
}

variable "o2_endpoint" {
  description = "OpenObserve HTTP endpoint"
  type        = string
  default     = "http://localhost:5080"
}

variable "o2_email" {
  description = "OpenObserve root user email"
  type        = string
  default     = "root@example.com"
}

variable "o2_password" {
  description = "OpenObserve root user password"
  type        = string
  sensitive   = true
}

variable "o2_organization" {
  description = "OpenObserve organization name"
  type        = string
  default     = "default"
}

variable "o2_insecure" {
  description = "Skip TLS verification (for local dev)"
  type        = bool
  default     = true
}

variable "rivulet_namespace" {
  description = "Namespace for Rivulet workloads"
  type        = string
  default     = "rivulet"
}

variable "sre_namespace" {
  description = "Namespace for AutoSRE agent"
  type        = string
  default     = "sre"
}

variable "o2_namespace" {
  description = "Namespace for OpenObserve"
  type        = string
  default     = "openobserve"
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "o2_endpoint" {
  description = "OpenObserve UI endpoint"
  value       = "${var.o2_endpoint}/web/"
}

output "o2_api_endpoint" {
  description = "OpenObserve API endpoint"
  value       = var.o2_endpoint
}

output "agent_webhook_url" {
  description = "AutoSRE agent webhook URL for alert ingestion"
  value       = "http://autosre-agent.${var.sre_namespace}.svc.cluster.local:8000/alerts"
}

output "otel_collector_endpoint" {
  description = "OpenTelemetry Collector OTLP/HTTP endpoint"
  value       = "http://otel-collector.${var.o2_namespace}.svc.cluster.local:4318"
}
