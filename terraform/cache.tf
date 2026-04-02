# Cache Rules (Free Plan: 10 rules max)

resource "cloudflare_ruleset" "cache_rules" {
  zone_id     = var.zone_id
  name        = "Homelab Cache Rules"
  description = "Caching configuration for ukkiee.dev"
  kind        = "zone"
  phase       = "http_request_cache_settings"

  # 정적 자산 장기 캐싱
  rules {
    ref         = "cache_static_assets"
    description = "Cache static assets (30d edge, 7d browser)"
    expression  = <<-EOT
      (http.request.uri.path.extension in {"js" "css" "png" "jpg" "jpeg" "gif" "svg" "woff2" "woff" "ico" "webp" "avif"})
    EOT
    action      = "set_cache_settings"
    action_parameters {
      cache = true
      edge_ttl {
        mode    = "override_origin"
        default = 2592000
      }
      browser_ttl {
        mode    = "override_origin"
        default = 604800
      }
    }
    enabled = true
  }

  # API 경로 캐시 바이패스
  rules {
    ref         = "bypass_api_cache"
    description = "Bypass cache for API endpoints"
    expression  = "(starts_with(http.request.uri.path, \"/api/\"))"
    action      = "set_cache_settings"
    action_parameters {
      cache = false
    }
    enabled = true
  }
}
