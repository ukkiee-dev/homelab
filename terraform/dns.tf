locals {
  apps  = jsondecode(file("${path.module}/apps.json"))
  infra = jsondecode(file("${path.module}/infra-hostnames.json"))
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

resource "cloudflare_dns_record" "infra" {
  for_each = local.infra

  zone_id = var.zone_id
  name    = each.value.subdomain
  type    = each.value.type
  content = each.value.content
  proxied = each.value.proxied
  ttl     = 1
}
