# Transform Rules - Security Response Headers (Free Plan: 10 rules max)

resource "cloudflare_ruleset" "security_headers" {
  zone_id     = var.zone_id
  name        = "Homelab Security Headers"
  description = "Add security response headers to all responses"
  kind        = "zone"
  phase       = "http_response_headers_transform"

  rules {
    ref         = "add_security_headers"
    description = "Add security headers to all responses"
    expression  = "(true)"
    action      = "rewrite"
    action_parameters {
      headers {
        name      = "X-Content-Type-Options"
        operation = "set"
        value     = "nosniff"
      }
      headers {
        name      = "X-Frame-Options"
        operation = "set"
        value     = "SAMEORIGIN"
      }
      headers {
        name      = "Referrer-Policy"
        operation = "set"
        value     = "strict-origin-when-cross-origin"
      }
      headers {
        name      = "Permissions-Policy"
        operation = "set"
        value     = "camera=(), microphone=(), geolocation=()"
      }
    }
    enabled = true
  }
}
