# OpenObserve provider configuration.
#
# The endpoint is normally the localhost port-forward established by the
# staging E2E script, for example:
#   http://localhost:5080
#
# Stream lifecycle is intentionally NOT managed by this provider configuration.
# Streams are created by scripts/staging/openobserve.sh before Terraform apply.

provider "openobserve" {
  endpoint = var.o2_endpoint
  username = var.o2_email
  password = var.o2_password
  org_id   = var.o2_organization
}
