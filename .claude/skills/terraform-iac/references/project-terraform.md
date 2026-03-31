# 프로젝트 Terraform 구성 레퍼런스

IaC 엔지니어가 이 프로젝트의 Terraform 코드를 작성할 때 참조하는 상세 가이드.

## 목차

1. [디렉토리 구조](#디렉토리-구조)
2. [apps.json 스키마](#appsjson-스키마)
3. [dns.tf 패턴](#dnstf-패턴)
4. [Provider 설정](#provider-설정)
5. [변수 체계](#변수-체계)
6. [CI 연동](#ci-연동)
7. [새 리소스 추가 가이드](#새-리소스-추가-가이드)

---

## 디렉토리 구조

```
terraform/
├── backend.tf        # R2 백엔드 + required_providers
├── provider.tf       # Cloudflare provider 설정
├── variables.tf      # 입력 변수 (API token, zone, tunnel, domain)
├── dns.tf            # 핵심 리소스 (cloudflare_record.apps)
└── apps.json         # 앱 레지스트리 (for_each 소스)
```

- `main.tf` 없음 — 기능별로 분리
- `outputs.tf` 없음 — 현재 출력 미정의
- `.terraform.lock.hcl`은 gitignore 대상

## apps.json 스키마

```json
{
  "<app-name>": {
    "subdomain": "<subdomain>"
  }
}
```

### 규칙

- **key** = 앱 이름: K8s namespace, ArgoCD app name, GHCR package name과 일치해야 함
- **subdomain**: DNS CNAME 레코드의 name 필드. 결과: `{subdomain}.ukkiee.dev`
- **공개 앱만 등록**: IngressRoute가 있는 public 앱만. worker/internal 앱은 등록하지 않음
- **중복 금지**: 앱 이름과 서브도메인 모두 유일해야 함
- **앱 이름 ≠ 서브도메인**: immich의 서브도메인은 photos (사용자 친화적 URL)

### 현재 등록 앱

```json
{
  "immich": { "subdomain": "photos" },
  "test-app": { "subdomain": "test-app" }
}
```

### 스키마 확장 시 주의

새 필드를 추가할 때는 optional로 만들어 기존 항목이 깨지지 않도록 한다:

```hcl
# 좋은 예: lookup으로 기본값 제공
proxied = lookup(each.value, "proxied", true)

# 나쁜 예: 필수 필드로 추가하면 기존 항목이 에러
proxied = each.value.proxied  # 기존 항목에 proxied가 없으면 실패
```

## dns.tf 패턴

```hcl
locals {
  apps = jsondecode(file("${path.module}/apps.json"))
}

resource "cloudflare_record" "apps" {
  for_each = local.apps
  zone_id  = var.zone_id
  name     = each.value.subdomain
  content  = "${var.tunnel_id}.cfargotunnel.com"
  type     = "CNAME"
  proxied  = true
}
```

### 리소스 주소

State에서의 주소: `cloudflare_record.apps["immich"]`, `cloudflare_record.apps["test-app"]`
key는 앱 이름(JSON key)이지 서브도메인이 아님에 주의.

### 새 리소스 타입 추가 시

`for_each = local.apps` 패턴과 proxied CNAME 패턴을 유지한다. 다른 레코드 타입이 필요하면 별도 resource 블록을 생성한다.

## Provider 설정

```hcl
# backend.tf
terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.48"
    }
  }
}

# provider.tf
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
```

- 현재 잠금 버전: 4.52.7
- CI에서 Terraform 1.7.0 사용
- API token에 Zone:DNS Edit + Tunnel Edit 권한 필요

## 변수 체계

| 변수 | 설명 | Sensitive | 기본값 |
|------|------|-----------|--------|
| `cloudflare_api_token` | Cloudflare API Token | yes | - |
| `zone_id` | ukkiee.dev Zone ID | yes | - |
| `tunnel_id` | cloudflared Tunnel ID | no | - |
| `account_id` | Cloudflare Account ID | no | - |
| `domain` | 기본 도메인 | no | `ukkiee.dev` |

모든 변수는 CI에서 `TF_VAR_*` 환경변수로 주입된다 (GitHub Secrets).

## CI 연동

Terraform apply는 GHA 워크플로우에서만 실행된다:

- **teardown.yml**: 앱 제거 시 apps.json에서 삭제 → terraform apply
- **audit-orphans.yml**: 주간 드리프트 감사 (plan 기반)
- **Concurrency**: `homelab-terraform` 그룹으로 직렬화

로컬에서는 plan까지만 실행한다. apply는 항상 CI 경유.

## 새 리소스 추가 가이드

1. `dns.tf`에 resource 블록 추가 (또는 기존 블록 확장)
2. 필요한 변수가 있으면 `variables.tf`에 추가
3. apps.json 스키마 변경이 필요하면 기존 항목과 호환되도록 optional 필드로 추가
4. CI 워크플로우에 새 변수의 `TF_VAR_*` 주입이 필요하면 별도 안내
