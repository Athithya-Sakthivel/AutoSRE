# ==============================================================================
# Production environment – illustrative production-grade values
#
# NOTE: This file is illustrative. It demonstrates what a production deployment
#       would use in a real Azure subscription with adequate quota and budget.
#       The current subscription (Azure for Students) cannot provision these
#       resources due to vCPU quota limits. 
# ==============================================================================

environment = "prod"
location    = "centralindia"

# ------------------------------------------------------------------------------
# AKS – Production
# ------------------------------------------------------------------------------

# Production workload: 3 nodes across availability zones.
# Each node: Standard_D4s_v4 (4 vCPU / 16 GiB RAM)
# Total: 12 vCPU / 48 GiB RAM
aks_vm_size            = "Standard_D4s_v4"
aks_node_count         = 3
aks_kubernetes_version = "1.36.3"
aks_os_disk_size_gb    = 100

# Enable availability zones for node pool resilience.
# Requires a region with 3 zones (centralindia supports this).
aks_availability_zones = ["1", "2", "3"]

# Use Azure CNI Overlay with Cilium (unchanged from staging).

# ------------------------------------------------------------------------------
# PostgreSQL – Production
# ------------------------------------------------------------------------------

# General Purpose SKU with zone-redundant high availability.
# 2 vCPU / 8 GiB RAM – suitable for moderate production workloads.
postgresql_version               = "18"
postgresql_sku_name              = "GP_Standard_D2s_v3"
postgresql_storage_mb            = 131072 # 128 GB
postgresql_backup_retention_days = 35     # Maximum supported

# Enable high availability (zone-redundant standby).
postgresql_high_availability_mode = "ZoneRedundant"

# ------------------------------------------------------------------------------
# Azure Container Registry – Production
# ------------------------------------------------------------------------------

# Standard SKU provides higher throughput, geo-replication, and private endpoints.
acr_sku = "Standard"

# Enable geo-replication for disaster recovery.
acr_geo_replication_locations = ["southindia"]

# ------------------------------------------------------------------------------
# Observability – Production
# ------------------------------------------------------------------------------

# 90 days retention for production auditing and trend analysis.
log_analytics_retention_days = 90

# 100% server-side sampling in production (cost is acceptable for this workload).
application_insights_sampling_percentage = 100

# All critical alerts enabled.
enable_cpu_alert              = true
enable_memory_alert           = true
enable_pod_restarts_alert     = true
enable_failed_requests_alert  = true
enable_postgres_storage_alert = true

# ------------------------------------------------------------------------------
# Budget & Cost Management
# ------------------------------------------------------------------------------

# Production cost estimate:
#   AKS (3 x D4s_v4)              ~ $450/month
#   PostgreSQL (GP_D2s_v3 + HA)   ~ $350/month
#   NAT Gateway + Public IP       ~ $35/month
#   ACR Standard                  ~ $25/month
#   Log Analytics / App Insights  ~ $25/month
#   Bandwidth / misc              ~ $50/month
#   --------------------------------
#   Approximate total             ~ $935/month
budget_monthly_amount = 1000

# Budget period – one year from deployment.
budget_start_date = "2026-09-01T00:00:00Z"
budget_end_date   = "2027-09-01T00:00:00Z"