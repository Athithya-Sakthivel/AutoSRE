# ==============================================================================
# Staging environment – non‑secret values only
# ==============================================================================

environment = "staging"
location    = "centralindia"

# AKS
aks_vm_size            = "Standard_D4s_v4"
aks_node_count         = 1
aks_kubernetes_version = "1.36"
aks_os_disk_size_gb    = 50

# PostgreSQL
postgresql_version               = "18"
postgresql_sku_name              = "B_Standard_B1ms"
postgresql_storage_mb            = 32768
postgresql_backup_retention_days = 7

# ACR
acr_sku = "Basic"

# Observability
log_analytics_retention_days             = 30
application_insights_sampling_percentage = 100 # Full telemetry in staging
enable_cpu_alert                         = true
enable_memory_alert                      = true
enable_pod_restarts_alert                = true
enable_failed_requests_alert             = false
enable_postgres_storage_alert            = false