# WAF Custom Rules (Free Plan: 5 rules max)

resource "cloudflare_ruleset" "waf_custom_rules" {
  zone_id     = var.zone_id
  name        = "Homelab WAF Custom Rules"
  description = "Custom WAF rules for ukkiee.dev homelab"
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  # Rule 1: 검증된 봇 허용 (Skip)
  rules {
    ref         = "allow_verified_bots"
    description = "Allow verified bots and trusted IP"
    expression  = var.trusted_ip != "" ? "(cf.client.bot) or (ip.src in {${var.trusted_ip}})" : "(cf.client.bot)"
    action      = "skip"
    action_parameters {
      ruleset = "current"
    }
    logging {
      enabled = true
    }
    enabled = true
  }

  # Rule 2: 한국 외 트래픽 챌린지
  rules {
    ref         = "geo_challenge_non_kr"
    description = "Challenge traffic from outside South Korea"
    expression  = "(not ip.geoip.country in {\"KR\"})"
    action      = "managed_challenge"
    enabled     = true
  }

  # Rule 3: 위협 점수 필터링
  rules {
    ref         = "threat_score_challenge"
    description = "Challenge high threat score requests"
    expression  = "(cf.threat_score gt 14)"
    action      = "managed_challenge"
    enabled     = true
  }

  # Rule 4: 악성 User-Agent 차단
  rules {
    ref         = "block_malicious_ua"
    description = "Block empty or malicious user agents"
    expression  = <<-EOT
      (http.user_agent eq "") or
      (http.user_agent contains "sqlmap") or
      (http.user_agent contains "nikto") or
      (http.user_agent contains "masscan") or
      (http.user_agent contains "zgrab") or
      (http.user_agent contains "python-requests")
    EOT
    action      = "block"
    enabled     = true
  }

  # Rule 5: 민감 경로 차단
  rules {
    ref         = "block_sensitive_paths"
    description = "Block probes for sensitive paths"
    expression  = <<-EOT
      (http.request.uri.path contains "/.env") or
      (http.request.uri.path contains "/.git") or
      (http.request.uri.path contains "/wp-login") or
      (http.request.uri.path contains "/wp-admin") or
      (http.request.uri.path contains "/xmlrpc") or
      (http.request.uri.path contains "/phpmyadmin")
    EOT
    action      = "block"
    enabled     = true
  }
}

# Rate Limiting (Free Plan: 1 rule max)

resource "cloudflare_ruleset" "rate_limiting" {
  zone_id     = var.zone_id
  name        = "Homelab Rate Limiting"
  description = "Rate limiting for ukkiee.dev"
  kind        = "zone"
  phase       = "http_ratelimit"

  rules {
    ref         = "rate_limit_login_paths"
    description = "Rate limit login and auth paths"
    expression  = <<-EOT
      (http.request.uri.path contains "/login") or
      (http.request.uri.path contains "/auth") or
      (http.request.uri.path contains "/api/auth")
    EOT
    action      = "block"
    ratelimit {
      characteristics     = ["cf.colo.id", "ip.src"]
      period              = 10
      requests_per_period = 20
      mitigation_timeout  = 10
    }
    enabled = true
  }
}
