# ==============================================================================
# Production environment – non‑secret values only
# ==============================================================================

environment = "prod"
location    = "centralindia"

# ------------------------------------------------------------------------------
# AKS
# ------------------------------------------------------------------------------

# A single-node production cluster is not ideal, but with a small vCPU quota
# and low expected traffic it is acceptable. For higher availability, consider
# increasing node_count after raising the regional vCPU quota.
aks_vm_size            = "Standard_D4s_v4" # 4 vCPU / 16 GiB RAM
aks_node_count         = 1
aks_kubernetes_version = "1.36"
aks_os_disk_size_gb    = 100

# Restrict public API server access to only the necessary CI/CD and admin
# egress IPs. Replace with real CIDR ranges for your environment.
# Example values below are placeholders and must be updated.
aks_authorized_ip_ranges = [
  "203.0.113.0/24",  # Office/Admin network
  "198.51.100.0/24", # VPN egress
]

# ------------------------------------------------------------------------------
# PostgreSQL
# ------------------------------------------------------------------------------

postgresql_version               = "18"
postgresql_sku_name              = "B_Standard_B1ms" # 1 vCPU / 2 GiB RAM
postgresql_storage_mb            = 65536             # 64 GB
postgresql_backup_retention_days = 35                # Maximum supported

# ------------------------------------------------------------------------------
# Azure Container Registry
# ------------------------------------------------------------------------------

# Basic SKU is sufficient for low-volume container pulls. For geo‑replication
# or higher throughput, consider Standard or Premium.
acr_sku = "Basic"

# ------------------------------------------------------------------------------
# Observability
# ------------------------------------------------------------------------------

# 30 days is a good default for production. Increase to 90 or 180 if needed.
log_analytics_retention_days = 30

# All critical alerts are enabled in production.
enable_cpu_alert              = true
enable_memory_alert           = true
enable_pod_restarts_alert     = true
enable_failed_requests_alert  = true
enable_postgres_storage_alert = true

# ------------------------------------------------------------------------------
# Budget & cost management
# ------------------------------------------------------------------------------

# Realistic monthly budget for a small production stack:
#   AKS node (1 x D4s_v4)        ~ $150/month
#   PostgreSQL (B1ms + storage)  ~ $25/month
#   NAT Gateway + Public IP      ~ $35/month
#   ACR Basic                    ~ $5/month
#   Log Analytics/App Insights   ~ $10/month
#   Bandwidth / misc             ~ $25/month
#   --------------------------------
#   Approximate total            ~ $250/month
budget_monthly_amount = 250

# Budget period – one year from deployment. Adjust as needed.
budget_start_date = "2026-09-01T00:00:00Z"
budget_end_date   = "2027-09-01T00:00:00Z"
