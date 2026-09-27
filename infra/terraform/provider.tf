# OpenObserve provider — v1.4.1.
#
# Accepted arguments per the provider schema:
#   endpoint, username, password, org_id
#
# Do NOT add `organization` or `insecure` — they are not in the schema and
# will fail with "Unsupported argument".

provider "openobserve" {
  endpoint = var.o2_endpoint
  username = var.o2_email
  password = var.o2_password
  org_id   = var.o2_organization
}
