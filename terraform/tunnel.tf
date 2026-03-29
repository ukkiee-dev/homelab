resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = var.account_id
  tunnel_id  = var.tunnel_id

  config {
    dynamic "ingress_rule" {
      for_each = local.apps
      content {
        hostname = "${ingress_rule.value.subdomain}.${var.domain}"
        service  = "http://traefik:80"
      }
    }

    # catch-all은 반드시 마지막
    ingress_rule {
      service = "http_status:404"
    }
  }
}
