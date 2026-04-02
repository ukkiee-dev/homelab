# Cloudflare Security & Performance Rules Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Cloudflare 무료 플랜에서 WAF, 캐싱, 보안 헤더, Rate Limiting 규칙을 Terraform으로 관리하여 홈랩 보안을 다계층으로 강화한다.

**Architecture:** 기존 `terraform/dns.tf` (CNAME 전용) 구조를 확장하여 `waf.tf`, `cache.tf`, `transform.tf` 3개 파일을 추가한다. 모든 규칙은 `cloudflare_ruleset` 리소스를 사용한다 (`cloudflare_firewall_rule`은 2025-06-15 deprecated). Provider는 현재 v4 (`~> 4.48`, 실제 `4.52.7`) 유지.

**Tech Stack:** Terraform (cloudflare provider v4), Cloudflare Free Plan, `cloudflare_ruleset` resource

**리서치 근거:** `_workspace/05_final_report.md` (3개 소스 교차 검증 완료)

---

## 사전 조건

### API Token 권한 확장

현재 토큰 권한: `Zone:DNS Edit + Tunnel Edit`

WAF/Rules 관리를 위해 **추가 필요한 권한**:
- **Zone > Firewall Services > Edit** — WAF Custom Rules, Rate Limiting
- **Zone > Zone Settings > Edit** — Configuration Rules (선택)
- **Zone > Dynamic URL Redirect > Edit** — Redirect Rules (선택)

> **중요**: Task 1 시작 전에 Cloudflare 대시보드에서 API Token 권한을 업데이트해야 한다.
> 경로: My Profile > API Tokens > 기존 토큰 편집 > Permissions 추가

### 현재 Terraform 구조

```
terraform/
  backend.tf        -- R2 원격 상태 (S3 호환)
  provider.tf       -- cloudflare provider ~> 4.48
  variables.tf      -- zone_id, tunnel_id, account_id, domain
  dns.tf            -- apps.json 기반 CNAME 레코드
  apps.json         -- {immich: {subdomain: "photos"}, test-web: {subdomain: "test-web"}}
```

### 목표 구조

```
terraform/
  backend.tf        -- (변경 없음)
  provider.tf       -- (변경 없음)
  variables.tf      -- trusted_ip 변수 추가
  dns.tf            -- (변경 없음)
  apps.json         -- (변경 없음)
  waf.tf            -- (신규) WAF Custom Rules 5개 + Rate Limiting 1개
  cache.tf          -- (신규) Cache Rules 2개
  transform.tf      -- (신규) 보안 응답 헤더 Transform Rule
```

---

## Task 1: variables.tf에 trusted_ip 변수 추가

**Files:**
- Modify: `terraform/variables.tf`

**왜:** WAF Rule 1(검증된 봇 허용)에서 자신의 IP를 화이트리스트에 추가하기 위한 변수. 선택적(Optional)으로 설계하여, IP가 없어도 검증된 봇만 허용하는 규칙은 작동하도록 한다.

**Step 1: variables.tf에 변수 추가**

`terraform/variables.tf` 파일 끝에 추가:

```hcl
variable "trusted_ip" {
  description = "Trusted IP address for WAF allow rule (optional)"
  type        = string
  default     = ""
}
```

**Step 2: Plan으로 검증**

```bash
cd terraform && terraform plan
```

Expected: 변수 추가만이므로 `No changes.` 출력

**Step 3: Commit**

```bash
git add terraform/variables.tf
git commit -m "feat(terraform): add trusted_ip variable for WAF rules"
```

---

## Task 2: WAF Custom Rules 생성 (waf.tf)

**Files:**
- Create: `terraform/waf.tf`

**왜:** Cloudflare 무료 플랜의 5개 WAF Custom Rules로 스캐닝 봇, 악성 UA, 고위험 트래픽을 차단한다. 3개 소스(Web, Academic, Community) 교차 검증 Confirmed.

**규칙 설계 근거:**

| # | 규칙 | Action | 근거 |
|---|------|--------|------|
| 1 | 검증된 봇 허용 | Skip | 후속 규칙에 Googlebot 등 차단 방지 |
| 2 | 한국 외 트래픽 챌린지 | Managed Challenge | 홈랩 주 사용자가 한국. Block 대신 Challenge로 VPN 오탐 최소화 (Community Disputed → Challenge로 합의) |
| 3 | Threat Score > 14 챌린지 | Managed Challenge | Cloudflare 위협 인텔리전스 기반 (Web + Community Confirmed) |
| 4 | 악성 UA 차단 | Block | 빈 UA + sqlmap/nikto/masscan/zgrab (Web + Community Confirmed) |
| 5 | 민감 경로 차단 | Block | .env/.git/wp-login/phpmyadmin — 홈랩에 없는 CMS 프로빙 (Web + Community Confirmed) |

**Step 1: waf.tf 파일 생성**

`terraform/waf.tf` 생성:

```hcl
# =============================================================================
# WAF Custom Rules (Free Plan: 5 rules max)
# 근거: _workspace/05_final_report.md 교차 검증 Confirmed
# =============================================================================

resource "cloudflare_ruleset" "waf_custom_rules" {
  zone_id     = var.zone_id
  name        = "Homelab WAF Custom Rules"
  description = "Custom WAF rules for ukkiee.dev homelab"
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  # Rule 1: 검증된 봇 허용 (Skip)
  # Googlebot, Bingbot 등이 후속 규칙(Geo 차단 등)에 걸리지 않도록 우선 허용
  rules {
    ref         = "allow_verified_bots"
    description = "Allow verified bots and trusted IP"
    expression  = var.trusted_ip != "" ? "(cf.client.bot) or (ip.src eq ${var.trusted_ip})" : "(cf.client.bot)"
    action      = "skip"
    action_parameters {
      ruleset = "current"
    }
    enabled = true
  }

  # Rule 2: 한국 외 트래픽 챌린지
  # Block 대신 Managed Challenge → VPN 사용자 오탐 최소화
  rules {
    ref         = "geo_challenge_non_kr"
    description = "Challenge traffic from outside South Korea"
    expression  = "(not ip.geoip.country in {\"KR\"})"
    action      = "managed_challenge"
    enabled     = true
  }

  # Rule 3: 위협 점수 필터링
  # cf.threat_score > 14: Cloudflare 위협 인텔리전스 기반
  rules {
    ref         = "threat_score_challenge"
    description = "Challenge high threat score requests"
    expression  = "(cf.threat_score gt 14)"
    action      = "managed_challenge"
    enabled     = true
  }

  # Rule 4: 악성 User-Agent 차단
  # 빈 UA + 알려진 스캐너/공격 도구
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
  # 존재하지 않는 CMS/설정 파일 프로빙 봇 차단
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

# =============================================================================
# Rate Limiting (Free Plan: 1 rule max)
# 제한: path + verified_bot 매칭만 가능, period 10초 고정
# =============================================================================

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
      characteristics     = ["ip.src"]
      period              = 10
      requests_per_period  = 20
      mitigation_timeout  = 10
    }
    enabled = true
  }
}
```

**Step 2: Plan으로 검증**

```bash
cd terraform && terraform plan
```

Expected: `Plan: 2 to add, 0 to change, 0 to destroy.`
- `cloudflare_ruleset.waf_custom_rules` will be created
- `cloudflare_ruleset.rate_limiting` will be created

> **주의**: `Error: Unauthorized` 발생 시 → API Token에 `Zone:Firewall Services Edit` 권한 추가 필요

**Step 3: Apply**

```bash
terraform apply
```

> `terraform plan`이 깨끗하면 apply. 에러 시 아래 트러블슈팅 참조.

**트러블슈팅:**

1. **`expression` 문법 에러**: Provider v4에서 `cloudflare_ruleset` expression은 Cloudflare Wirefilter 문법. `eq`, `contains`, `in`, `gt` 연산자 확인.

2. **`action_parameters` 에러 (Skip 규칙)**: Provider v4에서 Skip action의 `action_parameters` 구조가 다를 수 있음. 에러 시:
   ```hcl
   action_parameters {
     phases  = ["http_request_firewall_custom"]
   }
   ```
   또는:
   ```hcl
   action_parameters {
     ruleset = "current"
   }
   ```
   공식 문서: https://developers.cloudflare.com/terraform/additional-configurations/waf-custom-rules/

3. **`trusted_ip` 조건부 expression 에러**: 삼항 연산자가 Terraform에서 동작하나, Cloudflare expression 내부에서 변수 보간이 실패할 수 있음. 에러 시 trusted_ip 조건부 로직을 제거하고 `(cf.client.bot)` 만 사용.

4. **Rate Limiting `ratelimit` 블록 구조 에러**: Provider v4의 정확한 블록명이 `ratelimit`인지 `rate_limit`인지 확인 필요. 에러 시 `terraform providers schema -json | jq '.provider_schemas["registry.terraform.io/cloudflare/cloudflare"].resource_schemas["cloudflare_ruleset"]'`로 스키마 확인.

**Step 4: Cloudflare 대시보드에서 규칙 확인**

Security > WAF > Custom Rules 페이지에서 5개 규칙이 올바른 순서와 expression으로 생성되었는지 확인.

**Step 5: Commit**

```bash
git add terraform/waf.tf
git commit -m "feat(terraform): add WAF custom rules and rate limiting

- 5 WAF custom rules: verified bots skip, geo challenge, threat score,
  malicious UA block, sensitive paths block
- 1 rate limiting rule for login/auth paths
- Uses cloudflare_ruleset (not deprecated cloudflare_firewall_rule)"
```

---

## Task 3: Cache Rules 생성 (cache.tf)

**Files:**
- Create: `terraform/cache.tf`

**왜:** 정적 자산을 Edge에 장기 캐싱하여 origin(K3s) 부하를 줄이고, API 경로는 캐시를 바이패스하여 실시간 데이터를 보장한다.

**Step 1: cache.tf 파일 생성**

`terraform/cache.tf` 생성:

```hcl
# =============================================================================
# Cache Rules (Free Plan: 10 rules max)
# =============================================================================

resource "cloudflare_ruleset" "cache_rules" {
  zone_id     = var.zone_id
  name        = "Homelab Cache Rules"
  description = "Caching configuration for ukkiee.dev"
  kind        = "zone"
  phase       = "http_request_cache_settings"

  # Rule 1: 정적 자산 장기 캐싱
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

  # Rule 2: API 경로 캐시 바이패스
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
```

**Step 2: Plan으로 검증**

```bash
cd terraform && terraform plan
```

Expected: `Plan: 1 to add, 0 to change, 0 to destroy.`

**트러블슈팅:**

1. **`edge_ttl`/`browser_ttl` 블록 구조**: Provider v4에서 정확한 속성명이 `edge_ttl`인지 `edge_cache_ttl`인지 다를 수 있음. 에러 시 스키마 확인.

2. **`set_cache_settings` action**: Provider v4에서 지원 확인 필요. 미지원 시 이 Task를 건너뛰고 대시보드에서 수동 설정.

**Step 3: Apply**

```bash
terraform apply
```

**Step 4: Commit**

```bash
git add terraform/cache.tf
git commit -m "feat(terraform): add cache rules for static assets and API bypass"
```

---

## Task 4: Transform Rules — 보안 응답 헤더 (transform.tf)

**Files:**
- Create: `terraform/transform.tf`

**왜:** 모든 HTTP 응답에 보안 헤더(X-Content-Type-Options, X-Frame-Options, Referrer-Policy, Permissions-Policy)를 추가하여 클라이언트 측 공격(XSS, Clickjacking 등)을 완화한다.

**Step 1: transform.tf 파일 생성**

`terraform/transform.tf` 생성:

```hcl
# =============================================================================
# Transform Rules - Response Header Modification (Free Plan: 10 rules max)
# =============================================================================

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
```

**Step 2: Plan으로 검증**

```bash
cd terraform && terraform plan
```

Expected: `Plan: 1 to add, 0 to change, 0 to destroy.`

**트러블슈팅:**

1. **`headers` 블록 구조**: Provider v4에서 `headers` 블록의 정확한 구조가 다를 수 있음:
   ```hcl
   # 대안 구조
   action_parameters {
     headers = {
       "X-Content-Type-Options" = {
         operation = "set"
         value     = "nosniff"
       }
     }
   }
   ```
   에러 시 `terraform providers schema -json`으로 확인.

2. **Immich와의 호환성**: `X-Frame-Options: SAMEORIGIN`이 Immich iframe 사용을 방해할 수 있으나, Immich는 SPA이므로 문제 없을 것으로 예상. 문제 발생 시 Immich 서브도메인을 expression에서 제외:
   ```
   expression = "(not http.host eq \"photos.ukkiee.dev\")"
   ```

**Step 3: Apply**

```bash
terraform apply
```

**Step 4: 응답 헤더 확인**

```bash
curl -sI https://photos.ukkiee.dev | grep -iE "x-content-type|x-frame|referrer-policy|permissions-policy"
```

Expected:
```
x-content-type-options: nosniff
x-frame-options: SAMEORIGIN
referrer-policy: strict-origin-when-cross-origin
permissions-policy: camera=(), microphone=(), geolocation=()
```

**Step 5: Commit**

```bash
git add terraform/transform.tf
git commit -m "feat(terraform): add security response headers via transform rules"
```

---

## Task 5: API Token description 업데이트 + variables.tf description 수정

**Files:**
- Modify: `terraform/variables.tf:1-4`

**왜:** API Token에 Firewall Services Edit 권한이 추가되었으므로 description을 정확하게 반영한다.

**Step 1: variables.tf description 수정**

```hcl
# 기존
variable "cloudflare_api_token" {
  description = "Cloudflare API Token (Zone:DNS Edit + Tunnel Edit)"
  sensitive   = true
}

# 변경
variable "cloudflare_api_token" {
  description = "Cloudflare API Token (Zone:DNS Edit, Firewall Services Edit, Tunnel Edit)"
  sensitive   = true
}
```

**Step 2: Plan으로 검증**

```bash
cd terraform && terraform plan
```

Expected: `No changes.` (description은 메타데이터)

**Step 3: Commit**

```bash
git add terraform/variables.tf
git commit -m "docs(terraform): update API token description to reflect new permissions"
```

---

## Task 6: 대시보드 수동 설정 (Terraform 외)

**왜:** 일부 설정은 Terraform으로 관리하기보다 대시보드에서 1회 설정이 효율적이다. 이 Task는 수동 작업이며, 체크리스트로 관리한다.

### SSL/TLS 설정

- [ ] SSL/TLS > Overview > **Full (Strict)** 선택
- [ ] SSL/TLS > Edge Certificates > **Always Use HTTPS**: ON
- [ ] SSL/TLS > Edge Certificates > **Minimum TLS Version**: TLS 1.2
- [ ] SSL/TLS > Edge Certificates > **TLS 1.3**: Enabled
- [ ] SSL/TLS > Edge Certificates > **HSTS**: Enable
  - Max-Age: 6 months
  - Include subdomains: Yes (모든 서브도메인이 HTTPS일 때만)
  - No-Sniff: Yes
- [ ] SSL/TLS > Edge Certificates > **Automatic HTTPS Rewrites**: ON

### Security 설정

- [ ] Security > Settings > **Security Level**: Medium
- [ ] Security > Settings > **Browser Integrity Check**: ON
- [ ] Security > Settings > **Challenge Passage**: 1 hour
- [ ] Security > Bots > **Bot Fight Mode**: OFF (Immich 테스트 후 결정)
- [ ] Security > Bots > **Block AI Bots**: ON
- [ ] Security > Bots > **AI Labyrinth**: ON

### DNS 설정

- [ ] DNS > Settings > **DNSSEC**: Enable (DS 레코드를 도메인 레지스트라에 등록 필요)

### Speed/Performance 설정

- [ ] Speed > Optimization > **Auto Minify**: JS, CSS, HTML 모두 ON
- [ ] Speed > Optimization > **Early Hints**: ON
- [ ] Network > **HTTP/3 (QUIC)**: ON
- [ ] Network > **0-RTT Connection Resumption**: ON

### 확인

- [ ] curl로 SSL/TLS 확인: `curl -vI https://photos.ukkiee.dev 2>&1 | grep "TLS\|SSL"`
- [ ] HSTS 헤더 확인: `curl -sI https://photos.ukkiee.dev | grep strict-transport`

---

## Task 7: 통합 검증

**왜:** 모든 규칙이 올바르게 동작하는지 E2E 검증.

**Step 1: terraform state list로 리소스 확인**

```bash
cd terraform && terraform state list
```

Expected:
```
cloudflare_record.apps["immich"]
cloudflare_record.apps["test-web"]
cloudflare_ruleset.waf_custom_rules
cloudflare_ruleset.rate_limiting
cloudflare_ruleset.cache_rules
cloudflare_ruleset.security_headers
```

**Step 2: WAF 규칙 동작 확인**

```bash
# 민감 경로 차단 확인
curl -sI https://photos.ukkiee.dev/.env
# Expected: 403 Forbidden

# 빈 UA 차단 확인
curl -sI -H "User-Agent: " https://photos.ukkiee.dev/
# Expected: 403 Forbidden

# sqlmap UA 차단 확인
curl -sI -H "User-Agent: sqlmap/1.0" https://photos.ukkiee.dev/
# Expected: 403 Forbidden

# 정상 접근 확인
curl -sI https://photos.ukkiee.dev/
# Expected: 200 OK (또는 302 redirect to login)
```

**Step 3: 보안 헤더 확인**

```bash
curl -sI https://photos.ukkiee.dev/ | grep -iE "x-content-type|x-frame|referrer-policy|permissions-policy"
```

**Step 4: 캐시 헤더 확인**

```bash
# 정적 자산 캐시 확인
curl -sI https://photos.ukkiee.dev/favicon.ico | grep -iE "cf-cache-status|cache-control"
# Expected: cf-cache-status: HIT (2번째 요청부터) 또는 MISS (첫 요청)
```

**Step 5: Immich 모바일 앱 동작 확인**

- Immich 모바일 앱에서 사진 업로드/다운로드 테스트
- 해외 VPN 접속 시 Managed Challenge 표시되는지 확인
- 문제 발생 시 Rule 2(Geo Challenge) 비활성화 고려

---

## Task 8: Bot Fight Mode Immich 호환성 테스트 (선택)

**왜:** Bot Fight Mode는 무료 플랜에서 WAF Skip 불가하므로, Immich 모바일 앱 API 통신을 차단할 수 있다 (Community: Confirmed 함정).

**Step 1: Bot Fight Mode 활성화**

대시보드: Security > Bots > Bot Fight Mode: ON

**Step 2: Immich 앱 테스트**

- 모바일 앱에서 사진 목록 로드
- 새 사진 업로드
- 사진 다운로드

**Step 3: 결과에 따른 조치**

- **정상 동작**: Bot Fight Mode ON 유지
- **차단/오류 발생**: Bot Fight Mode OFF로 복원

> Pro 플랜($20/월)의 Super Bot Fight Mode는 WAF Skip 예외 설정 가능. 현재는 무료 플랜이므로 전체 On/Off만 가능.

---

## 리스크 및 롤백 계획

### 리스크 1: WAF 규칙이 정상 트래픽을 차단

**증상**: Immich 앱 접속 불가, 브라우저에서 Challenge 반복
**롤백**: 
```bash
cd terraform
# waf.tf에서 문제 규칙의 enabled = false로 변경 후
terraform apply
```
또는 Cloudflare 대시보드에서 즉시 규칙 비활성화 (대시보드 변경 후 terraform 상태와 드리프트 발생에 주의)

### 리스크 2: Terraform apply 실패

**증상**: API 권한 부족, expression 문법 에러
**롤백**: `terraform plan`에서 실패하므로 실제 적용 없음. 에러 메시지 기반으로 수정.

### 리스크 3: 대시보드 수동 설정과 Terraform 충돌

**증상**: 대시보드에서 수동으로 만든 규칙이 `terraform apply` 시 삭제
**방지**: 대시보드에서 WAF/Cache/Transform 규칙을 수동으로 생성하지 않음. Terraform이 해당 phase의 ruleset에 대해 배타적 소유권을 가짐.

---

## 향후 확장 (이번 플랜 범위 밖)

1. **Zero Trust Access**: 관리 서비스(Grafana, ArgoCD)에 이메일 OTP 인증 추가 → `terraform/zero-trust.tf`
2. **Terraform provider v5 마이그레이션**: 2026-03 마이그레이션 도구 릴리스 후 전환
3. **Cloudflare Access + Immich**: Immich 자체 인증과 Access의 이중 인증 구성
4. **Configuration Rules**: Terraform으로 Zone 설정 관리 (`cloudflare_zone_settings_override`)
