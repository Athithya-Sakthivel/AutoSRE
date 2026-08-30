terraform {
  required_version = ">= 1.6.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 5.19.0, < 6.0.0"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "cloudflare" {}
provider "tls" {}

# ------------------------------------------------------------------------------
# Variables
# ------------------------------------------------------------------------------

variable "account_id" {
  type = string
}

variable "zone_id" {
  type    = string
  default = null
}

variable "domain" {
  type = string
}

variable "subdomain" {
  description = "Subdomain prefix for the application"
  type        = string
  default     = "app"
}

variable "tunnel_name" {
  description = "Cloudflare Tunnel name used by cloudflared"
  type        = string
  default     = "task-api-default"
}

variable "enable_always_use_https" {
  type    = bool
  default = true
}

variable "enable_tls_1_3" {
  type    = bool
  default = true
}

variable "enable_bot_fight_mode" {
  type    = bool
  default = true
}

variable "enable_js_detections" {
  type    = bool
  default = true
}

variable "origin_ca_validity_days" {
  description = "Validity period for Origin CA certificate in days"
  type        = number
  default     = 5475  # 15 years

  validation {
    condition     = contains([7, 30, 90, 365, 730, 1095, 5475], var.origin_ca_validity_days)
    error_message = "Origin CA validity must be one of: 7, 30, 90, 365, 730, 1095, 5475 days."
  }
}

# ------------------------------------------------------------------------------
# Locals
# ------------------------------------------------------------------------------

locals {
  domain       = trim(var.domain, ".")
  subdomain    = trim(var.subdomain, ".")
  hostname     = "${local.subdomain}.${local.domain}"
  tunnel_cname = "${data.cloudflare_zero_trust_tunnel_cloudflared.default.id}.cfargotunnel.com"
}

# ------------------------------------------------------------------------------
# Existing Cloudflare Tunnel resources
# ------------------------------------------------------------------------------

data "cloudflare_zero_trust_tunnel_cloudflared" "default" {
  account_id = var.account_id

  filter = {
    name       = var.tunnel_name
    is_deleted = false
  }
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "default" {
  account_id = var.account_id
  tunnel_id  = data.cloudflare_zero_trust_tunnel_cloudflared.default.id
}

resource "cloudflare_dns_record" "app_cname" {
  zone_id = var.zone_id
  name    = local.hostname
  type    = "CNAME"
  content = local.tunnel_cname
  proxied = true
  ttl     = 1
}

# ------------------------------------------------------------------------------
# Zone Settings
# ------------------------------------------------------------------------------

resource "cloudflare_zone_setting" "ssl" {
  zone_id    = var.zone_id
  setting_id = "ssl"
  value      = "strict"
}

resource "cloudflare_zone_setting" "always_use_https" {
  count      = var.enable_always_use_https ? 1 : 0
  zone_id    = var.zone_id
  setting_id = "always_use_https"
  value      = "on"
}

resource "cloudflare_zone_setting" "tls_1_3" {
  count      = var.enable_tls_1_3 ? 1 : 0
  zone_id    = var.zone_id
  setting_id = "tls_1_3"
  value      = "on"
}

resource "cloudflare_bot_management" "zone" {
  zone_id = var.zone_id

  fight_mode = var.enable_bot_fight_mode
  enable_js  = var.enable_js_detections

  ai_bots_protection = "block"
  crawler_protection = "enabled"

  lifecycle {
    ignore_changes = [
      auto_update_model
    ]
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "default" {
  account_id = var.account_id
  tunnel_id  = data.cloudflare_zero_trust_tunnel_cloudflared.default.id

  config = {
    ingress = [
      {
        hostname = local.hostname
        service  = "http://frontend-stable.task-api.svc.cluster.local:8080"
      },
      {
        service = "http_status:404"
      }
    ]
  }
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------

output "cloudflare_tunnel_id" {
  value = data.cloudflare_zero_trust_tunnel_cloudflared.default.id
}

output "cloudflare_tunnel_name" {
  value = data.cloudflare_zero_trust_tunnel_cloudflared.default.name
}

output "cloudflare_tunnel_token" {
  value     = data.cloudflare_zero_trust_tunnel_cloudflared_token.default.token
  sensitive = true
}

output "app_url" {
  value = "https://${local.hostname}"
}
