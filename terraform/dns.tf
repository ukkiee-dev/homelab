locals {
  apps = jsondecode(file("${path.module}/apps.json"))
}


resource "cloudflare_dns_record" "apps" {
  for_each = local.apps

  zone_id = var.zone_id
  name    = each.value.subdomain
  content = "${var.tunnel_id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  ttl     = 1
}

moved {
  from = cloudflare_record.apps
  to   = cloudflare_dns_record.apps
}
