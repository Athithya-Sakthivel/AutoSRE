# ==============================================================================
# provider.tf — OpenObserve provider configuration
# ==============================================================================

provider "openobserve" {
  endpoint = var.o2_endpoint
  username = var.o2_email
  password = var.o2_password
  org_id   = var.o2_organization
}
