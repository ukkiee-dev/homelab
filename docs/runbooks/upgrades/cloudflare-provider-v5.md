# Cloudflare Terraform Provider v4.52.7 → v5.18.0 업그레이드 Runbook

| 항목 | 값 |
|------|-----|
| **심각도** | High (IaC state 조작 포함, 롤백 경로 필수) |
| **예상 소요** | 4.5 ~ 6시간 (migration 본체) + 1 ~ 2시간 (R2 신규, 별건 PR) |
| **최종 수정** | 2026-04-18 |
| **관련 서비스** | Cloudflare DNS / WAF / Cache / Ratelimit rules (zone `ukkiee.dev`), Terraform R2 state backend |
| **카테고리** | 인프라 관리 (major 업그레이드) |

---

## 1. 개요 / 사유

### 업그레이드 목적

홈랩 PostgreSQL 백업을 R2의 계층형 보존 정책 (daily/weekly/monthly) 으로 관리하기 위해 `cloudflare_r2_bucket_lifecycle` 리소스가 필수. 이 리소스는 v5 전용이며 v4에는 존재하지 않음 (breaking change item C-5).

### 현재 상태 핵심 사실

- **실제 설치된 v4 버전**: `4.52.7` (`terraform/.terraform.lock.hcl` line 5)
- 공식 권장 stepping-stone인 `v4.52.5`를 **이미 초과 충족**. 즉 **v4 자체의 추가 업그레이드(Phase 0)는 불필요**. `v4.48 → v4.52.5` 단계는 건너뛰고 바로 v5 migration 시작.
- **IaC 구조**: Terraform 모듈 미사용 (flat 구조). → W-3 "tf-migrate 모듈 미지원" 제약에서 자유. tf-migrate 100% 활용 가능.
- **영향 대상**: 4개 resource declaration / 5개 state instance (DNS 2 instance + ruleset 3개).

### 버전 pin 방침

- **타겟 버전**: `= 5.18.0` (정확한 `=` pin, `~> 5.18` 금지)
- **이유**:
  - v5.19는 beta (2026-04-07 기준 beta.5). 자동 state upgrader는 매력적이나 regression 위험.
  - v5.x 마이너에 breaking change 빈발 (v5.4, v5.6, v5.13). `~>` 제약은 자동으로 breaking 마이너로 튀어오를 수 있어 금지.
  - v5.18 은 ruleset/dns_record/r2_bucket 모두 stabilized 목록에 포함 (Issue #6237).
- **v5.19 재평가**: GA (2026-04-20 주 예상) 이후 별건 PR에서 `= 5.19.x`로 재업그레이드 검토.

### Edge 트래픽 영향

- **없음**. Cloudflare Edge 설정 (DNS 값, WAF rule 본체, cache rule 본체) 은 이미 Cloudflare API 상에 존재. Terraform의 리소스 rename/schema 재작성은 **state 레이어 작업**이며 API 호출을 동반하지 않음.
- **예외**: `terraform plan`이 destroy/recreate를 제시하면 즉시 중단. DNS record recreate 시 TTL (5분) 기준 최대 5분 단절 가능성.

### 참고 문서

- Breaking change 전수: `/Users/ukyi/homelab/_workspace/01_breaking_changes.md`
- 홈랩 영향 분석: `/Users/ukyi/homelab/_workspace/02_impact_analysis.md`
- Scope: `/Users/ukyi/homelab/_workspace/00_scope.md`
- 공식 upgrade guide: https://github.com/cloudflare/terraform-provider-cloudflare/blob/main/docs/guides/version-5-upgrade.md

---

## 2. 사전 점검 체크리스트

각 항목을 순서대로 확인하고 하나라도 통과하지 못하면 **작업 중단**. 모두 통과해야 Phase 1 진입.

### 2.1 v4 상태 drift 0 확인

```bash
cd /Users/ukyi/homelab/terraform

# 1) 로컬 state stub 초기화 (backend 연결)
terraform init

# 2) v4.52.7 기준 plan 실행
terraform plan -out=/tmp/pre-v5-plan.binary
```

**정상 출력**:
```
No changes. Your infrastructure matches the configuration.
```

**비정상 출력 예시**:
```
Plan: 0 to add, 2 to change, 0 to destroy.
  # cloudflare_ruleset.waf_custom_rules will be updated in-place
  ...
```

→ drift 있으면 먼저 해결. migration 중 drift가 섞이면 "어떤 변경이 migration 탓인지 원인 분리 불가". `terraform apply`로 맞추거나 `lifecycle.ignore_changes` 로 마스킹 후 재실행.

### 2.2 R2 state backend versioning 활성 확인

```bash
# backend 설정 확인 (수동 참조)
grep -A 10 'backend "s3"' /Users/ukyi/homelab/terraform/backend.tf
# bucket = "ukkiee-terraform-state", key = "homelab/terraform.tfstate"

# Cloudflare Dashboard에서 확인:
# Cloudflare > R2 > Buckets > ukkiee-terraform-state > Settings
# "Object Versioning" 이 Enabled 인지 확인
```

**체크**:
- [ ] R2 bucket `ukkiee-terraform-state` 에 versioning enabled
- [ ] 비활성이면 지금 활성화. 롤백 경로의 근간.

### 2.3 로컬 state backup 확보

```bash
cd /Users/ukyi/homelab/terraform
mkdir -p /Users/ukyi/homelab/_workspace
TS=$(date +%Y%m%d-%H%M%S)
terraform state pull > /Users/ukyi/homelab/_workspace/backup-${TS}.tfstate
ls -la /Users/ukyi/homelab/_workspace/backup-*.tfstate
```

**정상 출력** (파일 크기 수 KB ~ 수십 KB 내외):
```
-rw-r--r-- 1 user staff 12345 Apr 18 23:10 /Users/ukyi/homelab/_workspace/backup-20260418-231000.tfstate
```

**내용 검증**:
```bash
python3 -c "import json; s=json.load(open('/Users/ukyi/homelab/_workspace/backup-${TS}.tfstate')); print('version:', s.get('version')); print('serial:', s.get('serial')); print('resources:', len(s.get('resources', [])))"
```

**정상**: `resources: 4` (for_each 포함 5 instance).

**체크**:
- [ ] backup 파일 존재하고 크기 > 0
- [ ] `resources` 배열 길이 = 4
- [ ] 백업 파일 경로를 이후 섹션을 위해 환경변수로 보관:
  ```bash
  echo "export BACKUP_TFSTATE=/Users/ukyi/homelab/_workspace/backup-${TS}.tfstate" >> ~/.cf-v5-migration-vars
  source ~/.cf-v5-migration-vars
  ```

### 2.4 git branch 생성

```bash
cd /Users/ukyi/homelab
git status              # 클린 확인
git checkout main
git pull --ff-only
git checkout -b feat/cloudflare-v5
git branch --show-current
```

**체크**:
- [ ] 현재 브랜치 = `feat/cloudflare-v5`
- [ ] working tree clean

### 2.5 tf-migrate 설치 여부 확인

tf-migrate GA 예정일: **2026-04-20**. 오늘 (2026-04-18) 기준 beta.

```bash
# 설치 시도
which tf-migrate || echo "NOT INSTALLED"

# beta 다운로드 (macOS arm64, M4)
# Release: https://github.com/cloudflare/tf-migrate/releases
TFMIGRATE_VERSION="v0.1.0-beta.5"   # GA 이후 최신 안정 버전으로 교체
curl -fsSL -o /tmp/tf-migrate.tar.gz \
  "https://github.com/cloudflare/tf-migrate/releases/download/${TFMIGRATE_VERSION}/tf-migrate_${TFMIGRATE_VERSION}_darwin_arm64.tar.gz"
tar -xzf /tmp/tf-migrate.tar.gz -C /tmp/
sudo mv /tmp/tf-migrate /usr/local/bin/
tf-migrate version
```

**체크**:
- [ ] `tf-migrate version` 출력 성공
- [ ] GA 이후 작업이면 stable 버전 사용
- [ ] GA 전이고 beta가 불안해 보이면 **수동 편집 경로 (Phase 2 대안)** 로 진행 — 홈랩 리소스 5개뿐이라 수동도 현실적

### 2.6 Cloudflare API token 권한 현황 기록

현재 token은 `var.cloudflare_api_token` 으로 외부 주입됨. migration 자체는 기존 권한으로 충분하나, R2 리소스 추가 (Phase 5) 시점에 R2 권한 추가 필요.

**현재 token 권한 (변수 정의 `terraform/variables.tf` line 1-3 기반)**:
- Zone:DNS:Edit
- Zone:WAF:Edit
- Zone:Cache Rules:Edit
- Zone:Transform Rules:Edit
- Account:Cloudflare Tunnel:Edit

**migration 중 필요한 권한**: 위와 동일 (R2 제외). 추가 조치 불필요.

**Phase 5에서 필요**: **Workers R2 Storage:Edit** (Account scope) — migration 완료 후 별건 PR 준비 시 Cloudflare Dashboard에서 토큰 권한 추가.

**체크**:
- [ ] 현재 token이 Zone DNS/WAF/Cache/Transform + Account Tunnel 권한 보유
- [ ] R2 권한 추가는 Phase 5 시점에 별도 처리 (지금 하지 말 것 — scope 초과)

### 2.7 Terraform CLI 버전 확인

`moved` block 사용을 위해 Terraform 1.8+ 필요.

```bash
terraform version
```

**정상**: `Terraform v1.8.x` 이상.

**비정상**: `v1.7.x` 이하. `brew upgrade terraform` 으로 업그레이드.

**체크**:
- [ ] Terraform 1.8+ 설치됨

### 2.8 현재 리소스 인벤토리 기록

migration 중 import ID 매핑을 위해 현재 Cloudflare 측 resource ID 를 조회·보관.

```bash
export CF_ZONE_ID=$(terraform -chdir=/Users/ukyi/homelab/terraform output -raw zone_id 2>/dev/null || echo "<FILL_FROM_VAR>")
# output이 없으면 variables/tfvars에서 직접 가져올 것

# DNS record ID 목록
curl -s -H "Authorization: Bearer ${CF_API_TOKEN}" \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?per_page=100" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print(r['id'], r['name'], r['type']) for r in d['result']]" \
  | tee /Users/ukyi/homelab/_workspace/cf-dns-ids.txt

# Ruleset ID 목록 (zone)
curl -s -H "Authorization: Bearer ${CF_API_TOKEN}" \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/rulesets" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print(r['id'], r['phase'], r['name']) for r in d['result']]" \
  | tee /Users/ukyi/homelab/_workspace/cf-rulesets-ids.txt
```

**체크**:
- [ ] `cf-dns-ids.txt` 에 최소 `argo` CNAME, `test-web` CNAME 포함
- [ ] `cf-rulesets-ids.txt` 에 `http_request_cache_settings`, `http_request_firewall_custom`, `http_ratelimit` phase 각 1개씩 포함

**주의**: `CF_API_TOKEN` 환경변수는 현재 터미널 세션에만 export. `.bashrc`/`.zshrc` 에 기록 금지.

---

## 3. 단계별 마이그레이션 절차

### Phase 1: 사전 준비 (완료 상태 확인, 15분)

섹션 2 (사전 점검) 체크리스트 모두 통과했는지 재확인.

**완료 조건**:
- [ ] v4.52.7 drift 0
- [ ] R2 versioning enabled
- [ ] `$BACKUP_TFSTATE` 환경변수 설정 + 파일 존재
- [ ] feat/cloudflare-v5 브랜치 체크아웃
- [ ] tf-migrate 설치 (또는 수동 경로 결정)
- [ ] CF API 로 DNS/ruleset ID 목록 확보

→ 모두 체크되면 Phase 2 진입.

### Phase 2: tf-migrate 실행 (HCL 자동 재작성 + moved block 생성, 30분)

#### 2A. tf-migrate 자동 경로 (권장)

```bash
cd /Users/ukyi/homelab/terraform

# tf-migrate 실행
tf-migrate migrate \
  --source-version v4 \
  --target-version v5 \
  --output-dir . \
  --generate-moved-blocks
```

**예상 동작**:
- `dns.tf` 의 `cloudflare_record` → `cloudflare_dns_record` 리네임
- `cache.tf` / `waf.tf` 의 `rules { ... }` 반복 block → `rules = [ { ... } ]` list 전환
- `action_parameters { ... }` / `edge_ttl { ... }` / `browser_ttl { ... }` / `logging { ... }` / `ratelimit { ... }` → nested attribute (`=`) 로 전환
- `moved { from = ..., to = ... }` block 자동 생성 (별도 `.tf` 파일 또는 각 파일에 append)

#### 2B. 수동 경로 (tf-migrate 미설치 / beta 회피)

홈랩 리소스 5개뿐이라 수동 편집도 현실적. 각 파일에 대해 아래 변환 적용:

**`dns.tf`**:
```hcl
# BEFORE (v4)
resource "cloudflare_record" "apps" {
  for_each = local.apps
  zone_id  = var.zone_id
  name     = each.value.subdomain
  content  = "${var.tunnel_id}.cfargotunnel.com"
  type     = "CNAME"
  proxied  = true
}

# AFTER (v5)
resource "cloudflare_dns_record" "apps" {
  for_each = local.apps
  zone_id  = var.zone_id
  name     = each.value.subdomain   # zone_id 함께 있으면 FQDN 자동 확장. 2.8 주의 참조
  content  = "${var.tunnel_id}.cfargotunnel.com"
  type     = "CNAME"
  proxied  = true
  ttl      = 1                       # v5에서 proxied=true 시 ttl=1(auto) 명시 필요할 수 있음
}

moved {
  from = cloudflare_record.apps
  to   = cloudflare_dns_record.apps
}
```

**`cache.tf`** (핵심 패턴):
```hcl
# BEFORE (v4, block 반복)
resource "cloudflare_ruleset" "cache_rules" {
  zone_id     = var.zone_id
  name        = "Homelab Cache Rules"
  description = "Caching configuration for ukkiee.dev"
  kind        = "zone"
  phase       = "http_request_cache_settings"

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

# AFTER (v5, list + nested attribute)
resource "cloudflare_ruleset" "cache_rules" {
  zone_id     = var.zone_id
  name        = "Homelab Cache Rules"
  description = "Caching configuration for ukkiee.dev"
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules = [
    {
      ref         = "cache_static_assets"
      description = "Cache static assets (30d edge, 7d browser)"
      expression  = <<-EOT
        (http.request.uri.path.extension in {"js" "css" "png" "jpg" "jpeg" "gif" "svg" "woff2" "woff" "ico" "webp" "avif"})
      EOT
      action      = "set_cache_settings"
      action_parameters = {
        cache = true
        edge_ttl = {
          mode    = "override_origin"
          default = 2592000
        }
        browser_ttl = {
          mode    = "override_origin"
          default = 604800
        }
      }
      enabled = true
    },
    {
      ref         = "bypass_api_cache"
      description = "Bypass cache for API endpoints"
      expression  = "(starts_with(http.request.uri.path, \"/api/\"))"
      action      = "set_cache_settings"
      action_parameters = {
        cache = false
      }
      enabled = true
    },
  ]
}

# cloudflare_ruleset은 v4 ↔ v5 이름 동일. moved block 불필요.
# 단 schema 변경 때문에 "no schema available" 에러 발생 시 state rm + import 필요 (Phase 3 시나리오 B/C)
```

**`waf.tf`** (2개 ruleset, 동일 패턴):
- `cloudflare_ruleset.waf_custom_rules` (phase `http_request_firewall_custom`, 5 rules):
  - `rules { ... }` → `rules = [ { ... } ]` (5개 element)
  - `action_parameters { ruleset = "current" }` → `action_parameters = { ruleset = "current" }`
  - `logging { enabled = true }` → `logging = { enabled = true }`
  - heredoc expression (`<<-EOT ... EOT`), ternary (`var.trusted_ip != "" ? ... : ...`) 모두 **그대로 유지** (HCL 문자열/expression 처리는 provider 와 무관)
- `cloudflare_ruleset.rate_limiting` (phase `http_ratelimit`, 1 rule):
  - `rules { ... }` → `rules = [ { ... } ]`
  - `action_parameters { ruleset = "current" }` 없음. 원래 rate_limit 리소스는 `action_parameters` 자체가 rule 내부에 없었음 → 변경 없음
  - `ratelimit { characteristics = [...], period = ..., requests_per_period = ..., mitigation_timeout = ... }` → `ratelimit = { characteristics = [...], period = ..., requests_per_period = ..., mitigation_timeout = ... }`

**편집 후 공통 작업**:
```bash
cd /Users/ukyi/homelab/terraform
terraform fmt
git diff
```

**체크포인트 (Phase 2 완료 조건)**:
- [ ] `dns.tf` 에 `cloudflare_dns_record` 사용 + `moved` block 존재
- [ ] `cache.tf`, `waf.tf` 의 모든 `rules { ... }`, `action_parameters { ... }`, `edge_ttl`, `browser_ttl`, `logging`, `ratelimit` block 이 `=` 문법 nested attribute 로 전환됨
- [ ] `terraform fmt` 클린 통과
- [ ] `git diff` 검토 완료 — DNS 타입명 변경 + moved block + ruleset HCL 재구성이 전부
- [ ] 아직 `terraform init` / `plan` 실행 안 함 (Phase 3 에서 provider 교체와 함께)

### Phase 3: Provider 교체 + state migration (1.5 ~ 2.5시간)

#### 3.1 provider.tf 수정

```bash
cd /Users/ukyi/homelab/terraform
```

`backend.tf` 의 `required_providers` 블록 (line 2-7) 을 다음과 같이 수정:

```hcl
# BEFORE
required_providers {
  cloudflare = {
    source  = "cloudflare/cloudflare"
    version = "~> 4.48"
  }
}

# AFTER
required_providers {
  cloudflare = {
    source  = "cloudflare/cloudflare"
    version = "= 5.18.0"        # 정확한 pin. ~> 5.18 금지
  }
}
```

주: 홈랩은 `required_providers` 가 `provider.tf` 가 아닌 `backend.tf` 의 `terraform {}` 블록 안에 있을 수 있음. 실제 파일 구조 기준으로 편집. 현재 (2026-04-18) 구조 확인:

```bash
grep -n "required_providers\|version" /Users/ukyi/homelab/terraform/backend.tf /Users/ukyi/homelab/terraform/provider.tf
```

#### 3.2 lock.hcl 제거 후 재초기화

```bash
cd /Users/ukyi/homelab/terraform

# lock.hcl 백업 후 제거
cp .terraform.lock.hcl /Users/ukyi/homelab/_workspace/lock-v4.52.7.hcl
rm .terraform.lock.hcl

# provider 다운로드
terraform init -upgrade
```

**예상 출력**:
```
Initializing the backend...
Initializing provider plugins...
- Finding cloudflare/cloudflare versions matching "5.18.0"...
- Installing cloudflare/cloudflare v5.18.0...
- Installed cloudflare/cloudflare v5.18.0 (signed by HashiCorp)
Terraform has been successfully initialized!
```

**검증**:
```bash
grep -A 2 'cloudflare/cloudflare' .terraform.lock.hcl | head -5
# version     = "5.18.0"
```

#### 3.3 Plan 실행 — 3가지 시나리오 분기

```bash
terraform plan -out=/tmp/v5-plan.binary 2>&1 | tee /tmp/v5-plan.out
```

출력 분석:

---

##### 시나리오 A: moved block 만으로 완료 (가장 좋음)

**증상**:
```
# cloudflare_record.apps["argocd"] has moved to cloudflare_dns_record.apps["argocd"]
# cloudflare_record.apps["test-web"] has moved to cloudflare_dns_record.apps["test-web"]
# cloudflare_ruleset.cache_rules will be updated in-place (또는 No changes)
# cloudflare_ruleset.waf_custom_rules will be updated in-place
# cloudflare_ruleset.rate_limiting will be updated in-place

Plan: 0 to add, 0 or N to change, 0 to destroy.
```

또는 완전히 `No changes.`

**조치**:
1. destroy 액션이 **0** 임을 반드시 확인.
2. in-place change 내용 육안 검토 — schema field 이름 변경 (block → attribute) 만 있어야 함. 실제 값 변경은 없어야 정상.
3. `terraform apply /tmp/v5-plan.binary` 실행.
4. Phase 4 (apply + 검증) 로 이동.

**destroy 가 1 건이라도 있으면**: **apply 금지**. 시나리오 B 로 전환.

---

##### 시나리오 B: 일부 리소스 state rm + import (ruleset 예상)

**증상**:
```
Plan: 3 to add, 0 to change, 3 to destroy.
  # cloudflare_ruleset.cache_rules will be destroyed
  # cloudflare_ruleset.cache_rules will be created
  ...
```

또는:
```
Error: Missing required argument
  on cache.tf line 3, in resource "cloudflare_ruleset" "cache_rules":
  The argument "rules" is required, but no definition was found.
```

**원인**: schema 가 block → list attribute 로 변경되어 v4 state 와 v5 config 간 불일치. `moved` block 만으로 부족.

**조치** (ruleset 3개 각각에 대해):

```bash
cd /Users/ukyi/homelab/terraform

# 1) cache_rules
# a) 현재 state 에서 ID 추출
CACHE_RULESET_ID=$(terraform state show cloudflare_ruleset.cache_rules | grep '^id' | awk '{print $3}' | tr -d '"')
echo "cache_rules id: $CACHE_RULESET_ID"

# state 에서 추출 불가 시 (이미 삭제된 경우) cf-rulesets-ids.txt 에서 찾기
grep http_request_cache_settings /Users/ukyi/homelab/_workspace/cf-rulesets-ids.txt

# b) state 제거
terraform state rm cloudflare_ruleset.cache_rules

# c) v5 provider 로 import
terraform import cloudflare_ruleset.cache_rules "${CF_ZONE_ID}/${CACHE_RULESET_ID}"
```

**import ID 형식 cheatsheet**:
| 리소스 | Import ID 형식 | ID 조회 방법 |
|---|---|---|
| `cloudflare_dns_record` | `<zone_id>/<record_id>` | `GET /zones/<zone_id>/dns_records` 의 `result[].id`. Cheatsheet: `/Users/ukyi/homelab/_workspace/cf-dns-ids.txt` |
| `cloudflare_ruleset` | `<zone_id>/<ruleset_id>` | `GET /zones/<zone_id>/rulesets` 의 `result[].id`. Cheatsheet: `/Users/ukyi/homelab/_workspace/cf-rulesets-ids.txt` |
| `cloudflare_r2_bucket` | `<account_id>/<bucket_name>/<jurisdiction>` (3-part, jurisdiction 기본 `default`) | 미사용 (Phase 5 에서만) |

**for_each DNS record 처리**:
DNS record 가 `moved` block 으로 해결되지 않으면:
```bash
# argo
ARGO_REC_ID=$(grep '^.*argo\.ukkiee\.dev' /Users/ukyi/homelab/_workspace/cf-dns-ids.txt | awk '{print $1}')
terraform state rm 'cloudflare_dns_record.apps["argocd"]'
terraform import 'cloudflare_dns_record.apps["argocd"]' "${CF_ZONE_ID}/${ARGO_REC_ID}"

# test-web
TESTWEB_REC_ID=$(grep '^.*test-web\.ukkiee\.dev' /Users/ukyi/homelab/_workspace/cf-dns-ids.txt | awk '{print $1}')
terraform state rm 'cloudflare_dns_record.apps["test-web"]'
terraform import 'cloudflare_dns_record.apps["test-web"]' "${CF_ZONE_ID}/${TESTWEB_REC_ID}"
```

주의: for_each 키를 bash 에서 escape 하려면 single quote + double quote 조합 필요: `'cloudflare_dns_record.apps["argocd"]'`.

**각 import 이후**:
```bash
terraform plan
```
→ 해당 리소스가 plan 에서 "No changes" 로 바뀌는지 확인. 잔여 drift 있으면 drift 내용 검토 후 HCL 재조정.

**모든 리소스 import 후**:
```bash
terraform plan
```
→ 최종 "No changes" 도달까지 반복.

---

##### 시나리오 C: 전체 state rm + 전체 import ("no schema available")

**증상**:
```
Error: no schema available for cloudflare_record.apps["argocd"] while reading state; this is a bug in Terraform
Error: AttributeName("config"): invalid JSON, expected "{", got "["
```

**원인**: v4 state 를 v5 provider 가 완전히 읽지 못함 (GitHub Issue #4982, #6580). moved block 도 state 읽기 실패해서 동작 안 함.

**조치**: 5개 state instance 전부 제거 후 재import.

```bash
cd /Users/ukyi/homelab/terraform

# 1) 전체 state rm
terraform state rm 'cloudflare_record.apps'          # for_each 모두 제거
terraform state rm cloudflare_ruleset.cache_rules
terraform state rm cloudflare_ruleset.waf_custom_rules
terraform state rm cloudflare_ruleset.rate_limiting

# 2) state 비었는지 확인
terraform state list
# (출력이 비어야 함)

# 3) 신규 v5 리소스명으로 전체 import
ARGO_REC_ID=$(grep 'argo\.ukkiee\.dev' /Users/ukyi/homelab/_workspace/cf-dns-ids.txt | awk '{print $1}')
TESTWEB_REC_ID=$(grep 'test-web\.ukkiee\.dev' /Users/ukyi/homelab/_workspace/cf-dns-ids.txt | awk '{print $1}')
CACHE_RULESET_ID=$(grep 'http_request_cache_settings' /Users/ukyi/homelab/_workspace/cf-rulesets-ids.txt | awk '{print $1}')
WAF_RULESET_ID=$(grep 'http_request_firewall_custom' /Users/ukyi/homelab/_workspace/cf-rulesets-ids.txt | awk '{print $1}')
RL_RULESET_ID=$(grep 'http_ratelimit' /Users/ukyi/homelab/_workspace/cf-rulesets-ids.txt | awk '{print $1}')

terraform import 'cloudflare_dns_record.apps["argocd"]' "${CF_ZONE_ID}/${ARGO_REC_ID}"
terraform import 'cloudflare_dns_record.apps["test-web"]' "${CF_ZONE_ID}/${TESTWEB_REC_ID}"
terraform import cloudflare_ruleset.cache_rules "${CF_ZONE_ID}/${CACHE_RULESET_ID}"
terraform import cloudflare_ruleset.waf_custom_rules "${CF_ZONE_ID}/${WAF_RULESET_ID}"
terraform import cloudflare_ruleset.rate_limiting "${CF_ZONE_ID}/${RL_RULESET_ID}"

# 4) state 5 instance 확인
terraform state list
```

**정상 출력**:
```
cloudflare_dns_record.apps["argocd"]
cloudflare_dns_record.apps["test-web"]
cloudflare_ruleset.cache_rules
cloudflare_ruleset.waf_custom_rules
cloudflare_ruleset.rate_limiting
```

```bash
# 5) plan 재실행 → No changes 까지 반복
terraform plan
```

**드리프트 반복 시** (Warning W-1):
- `ratelimit`, `preserve_duplicates` 같은 특정 필드에서 3~5회 드리프트 가능.
- 같은 drift 가 3회 연속 나오면 해당 필드를 HCL 에서 정확한 v5 schema 로 재조정 또는 임시:
  ```hcl
  lifecycle {
    ignore_changes = [rules[0].action_parameters.preserve_duplicates]
  }
  ```
  (임시 조치. migration 후 제거)

---

#### 3.4 Phase 3 체크포인트

- [ ] `.terraform.lock.hcl` 의 provider version = `5.18.0`
- [ ] `terraform state list` 출력 = 5 instance (위 목록과 동일)
- [ ] `terraform plan` → "No changes" (3회 연속 동일 결과)
- [ ] destroy 액션 0
- [ ] apply 전에 **Phase 4** 로 이동 (별 단계)

### Phase 4: apply + 검증 (30분)

#### 4.1 apply 실행

```bash
cd /Users/ukyi/homelab/terraform
terraform plan -out=/tmp/v5-final-plan.binary
terraform apply /tmp/v5-final-plan.binary
```

만약 Phase 3 에서 plan 결과가 "No changes" 였다면 이 apply 는 0 변경. state 쪽만 정합. Cloudflare API 호출 없음.

#### 4.2 Cloudflare Dashboard 검증

브라우저로 https://dash.cloudflare.com → zone `ukkiee.dev`:

**DNS 검증** (Cloudflare > Websites > ukkiee.dev > DNS > Records):
- [ ] `argo` CNAME → `<tunnel_id>.cfargotunnel.com` (Proxied, orange cloud)
- [ ] `test-web` CNAME → `<tunnel_id>.cfargotunnel.com` (Proxied)

**Cache Rules 검증** (Caching > Cache Rules):
- [ ] "Homelab Cache Rules" ruleset 존재
- [ ] `cache_static_assets` rule — extension filter, edge 30d / browser 7d
- [ ] `bypass_api_cache` rule — `/api/` prefix, cache = false

**WAF 검증** (Security > WAF > Custom rules):
- [ ] "Homelab WAF Custom Rules" ruleset 존재
- [ ] 5개 rule: `allow_verified_bots`, `geo_challenge_non_kr`, `threat_score_challenge`, `block_malicious_ua`, `block_sensitive_paths`
- [ ] 각 rule action 일치 (skip, managed_challenge, managed_challenge, block, block)

**Rate Limiting 검증** (Security > WAF > Rate limiting rules):
- [ ] "Homelab Rate Limiting" ruleset 존재
- [ ] `rate_limit_login_paths` rule, 10s period / 20 rpp / 10s timeout

#### 4.3 DNS 실 응답 확인

```bash
dig +short argo.ukkiee.dev
dig +short test-web.ukkiee.dev
```

**정상**: Cloudflare anycast IP 반환 (`104.21.x.x` 또는 `172.67.x.x` 등 Cloudflare 범위). Tunnel CNAME 이지만 proxied 이므로 최종 응답은 CF edge IP.

#### 4.4 Phase 4 체크포인트

- [ ] apply 성공 (exit 0)
- [ ] Dashboard DNS 2 records 일치
- [ ] Dashboard cache rules 2개 일치
- [ ] Dashboard WAF custom rules 5개 일치
- [ ] Dashboard rate limiting 1개 일치
- [ ] `dig` 응답 정상 (argo + test-web)

### Phase 5: R2 리소스 추가 (별건 PR — 여기서는 하지 말 것)

**절대 이 runbook 의 같은 PR에 포함하지 말 것**. 이유:
1. Migration 은 "state 정합" 이 목적. R2 신규 리소스 추가는 "기능 확장" 이므로 분리 원칙.
2. R2 는 API 호출 실제 발생 (bucket create). 문제 발생 시 migration 롤백과 R2 rollback 이 섞이면 디버깅 복잡.
3. R2 권한 추가가 선행 필요 (Cloudflare Dashboard token edit).

**후속 PR 범위 힌트** (이 runbook 의 scope 밖):
- `terraform/r2.tf` 신규 작성:
  - `cloudflare_r2_bucket.postgres_backups` (location = `apac`, jurisdiction = `default`)
  - `cloudflare_r2_bucket_lifecycle.postgres_backups` (rules: daily/7d, weekly/30d, monthly/90d)
  - `cloudflare_r2_bucket_lifecycle` 은 **`terraform import` 미지원** — 처음부터 terraform 으로만 생성.
- API token 권한 추가: Cloudflare Dashboard > My Profile > API Tokens > edit > permissions 에서 "Workers R2 Storage:Edit" (Account scope) 추가
- 추가 tfvars: 필요 시 bucket name 을 변수화

---

## 4. 트래픽 전환 전략

### 4.1 무중단 가능 여부

**무중단** — 아래 조건 하에서:

| 조건 | 상태 | 비고 |
|---|---|---|
| Cloudflare Edge 설정 불변 | O | Migration 은 state 레이어 작업. API 호출 없음 |
| DNS record TTL 유지 | O | `moved` block 또는 `state rm + import` 둘 다 실제 DNS 값 변경 없음 |
| WAF/Cache rule 본체 불변 | O | Ruleset ID 보존 (import 시 동일 ID 재부착) |

### 4.2 중단 위험 조건

`terraform plan` 이 **다음 중 하나라도** 보이면 **즉시 apply 중단**:
- `cloudflare_dns_record.apps[...]` 에 **destroy** 액션 (DNS record 재생성 시 TTL 5분 기준 단절 가능)
- `cloudflare_ruleset.*` 에 **destroy + create** (rule 일시 제거 후 재생성 — 그 순간 WAF 미적용, 보안 공백)

**즉시 중단 후 조치**:
1. apply 하지 말고 `Ctrl+C`
2. 시나리오 B / C 로 전환 (state rm + import)
3. plan 결과가 "No changes" 또는 "in-place change (schema field rename only)" 가 될 때까지 재조정

### 4.3 Dashboard 수동 변경 금지 창

Phase 1 시작 ~ Phase 4 완료 기간 동안 **Cloudflare Dashboard 에서 DNS/WAF/Cache/Ratelimit 직접 수정 금지**.

- 수정 시 migration 후 drift 누적. state 와 실체 불일치 조사 난이도 상승.
- 긴급 수정 필요하면 Dashboard 수정 후 즉시 메모 → migration 완료 후 `terraform plan` 에서 반드시 해당 drift 를 `apply` 로 state 동기화.

---

## 5. 롤백 절차

### 5.1 롤백 트리거 조건

다음 중 하나라도 발생 시 롤백 검토:

- `terraform plan` 에 destroy 액션 포함 + state rm/import 로 3회 시도해도 drift 잔존
- `terraform apply` 도중 에러 + state lock 지속 (30분 이상)
- Cloudflare Dashboard 에서 rule 구성이 migration 전과 다름 발견 (apply 후)
- v5 provider regression 이 홈랩 쪽 리소스에 영향

### 5.2 롤백 단계

#### 5.2.1 git revert

```bash
cd /Users/ukyi/homelab
git status
# feat/cloudflare-v5 브랜치에 있을 것

# apply 전 롤백이면:
git checkout main
git branch -D feat/cloudflare-v5
# 변경 전부 파기

# apply 후 롤백이면 (더 신중):
# 커밋 했다면
git log --oneline -10
git revert <v5-migration-commit-sha>
```

#### 5.2.2 terraform lock.hcl 복원

```bash
cd /Users/ukyi/homelab/terraform
cp /Users/ukyi/homelab/_workspace/lock-v4.52.7.hcl .terraform.lock.hcl
```

또는 HCL 쪽 `version = "= 5.18.0"` 을 `version = "~> 4.48"` 로 되돌린 후 `rm .terraform.lock.hcl && terraform init -upgrade`.

#### 5.2.3 R2 state 복원 — 이중 경로

**경로 A: R2 versioning 에서 복원 (권장)**

```bash
# Cloudflare Dashboard > R2 > ukkiee-terraform-state > objects > homelab/terraform.tfstate > Versions
# Phase 1 시점의 version 선택 → "Restore this version"
# 또는 CLI (rclone, wrangler 등) 로 버전 ID 지정 복원
```

**경로 B: 로컬 backup 에서 복원 (Fallback)**

```bash
cd /Users/ukyi/homelab/terraform
ls $BACKUP_TFSTATE
# 예: /Users/ukyi/homelab/_workspace/backup-20260418-231000.tfstate

terraform state push $BACKUP_TFSTATE
```

**주의**: `terraform state push` 는 serial number 가 현재 state 보다 낮으면 reject 됨. 강제 덮어쓰기:
```bash
terraform state push -force $BACKUP_TFSTATE
```
이것도 reject 되면 R2 에서 직접 파일 교체 (R2 Dashboard 또는 rclone) 후 `terraform init -reconfigure`.

#### 5.2.4 v4 provider 로 plan 재실행

```bash
cd /Users/ukyi/homelab/terraform
terraform init -upgrade    # v4.52.7 pull
terraform plan
```

**정상**: `No changes.` — v4.52.7 시절과 동일 state 상태.

**비정상** (v5 로 이미 apply 한 후 롤백):
- Cloudflare API 상 리소스는 여전히 v5 schema 로 생성되어 있음. v4 provider 의 read 가 미세 drift 감지 가능.
- `terraform plan` 의 in-place change 가 "schema field format" 수준이라면 `terraform apply` 하지 말고 `lifecycle.ignore_changes` 로 마스킹.
- **destroy 액션이 보이면 apply 금지** — 재해 확대.

### 5.3 롤백 후 검증

```bash
cd /Users/ukyi/homelab/terraform
terraform plan
# No changes.

terraform state list
# cloudflare_record.apps["argocd"]
# cloudflare_record.apps["test-web"]
# cloudflare_ruleset.cache_rules
# cloudflare_ruleset.waf_custom_rules
# cloudflare_ruleset.rate_limiting

dig +short argo.ukkiee.dev         # CF edge IP
dig +short test-web.ukkiee.dev     # CF edge IP
```

**체크**:
- [ ] `.terraform.lock.hcl` version = `4.52.7`
- [ ] `terraform state list` 에 v4 리소스 이름 (`cloudflare_record.apps[...]`) 존재
- [ ] plan 결과 "No changes"
- [ ] dig 응답 정상

### 5.4 롤백 후 follow-up

1. 실패 원인 분석 (`/Users/ukyi/homelab/_workspace/v5-plan.out` 보관)
2. v5.19 GA (예상 2026-04-20 주) 대기 후 automatic state upgrader 로 재시도 검토
3. 문제 재발 방지 조치 (Known Gotchas 섹션 업데이트)

---

## 6. 업그레이드 후 검증 체크리스트

### 6.1 Terraform 레이어

```bash
cd /Users/ukyi/homelab/terraform

# 1) plan 3회 연속 No changes
for i in 1 2 3; do
  echo "=== Attempt $i ==="
  terraform plan -no-color 2>&1 | grep -E "No changes|Plan:"
  sleep 5
done
# 기대: "No changes." 3회
```

- [ ] `terraform plan` → "No changes" 3회 연속 (drift 없음)
- [ ] `terraform providers` 출력에 `cloudflare/cloudflare v5.18.0` 표시

```bash
terraform providers
# Providers required by configuration:
#   provider[registry.terraform.io/cloudflare/cloudflare] = 5.18.0
```

- [ ] `.terraform.lock.hcl` 의 `version` line = `"5.18.0"`

```bash
grep '^\s*version' /Users/ukyi/homelab/terraform/.terraform.lock.hcl
# version     = "5.18.0"
```

- [ ] `terraform state list` = 5 instance (DNS 2 + ruleset 3)

### 6.2 Cloudflare Edge 구성 (Dashboard 육안 검증)

**DNS** (2 records):
- [ ] `argo.ukkiee.dev` CNAME → `<tunnel_id>.cfargotunnel.com`, Proxied (orange)
- [ ] `test-web.ukkiee.dev` CNAME → `<tunnel_id>.cfargotunnel.com`, Proxied

**Cache Rules** (2개):
- [ ] `cache_static_assets`: extension filter, edge 30d, browser 7d
- [ ] `bypass_api_cache`: `/api/` prefix, cache disabled

**WAF Custom Rules** (5개):
- [ ] `allow_verified_bots`: skip action
- [ ] `geo_challenge_non_kr`: managed_challenge
- [ ] `threat_score_challenge`: managed_challenge
- [ ] `block_malicious_ua`: block
- [ ] `block_sensitive_paths`: block

**Rate Limiting** (1개):
- [ ] `rate_limit_login_paths`: block, 20 rpp / 10s period

### 6.3 DNS 실 응답

```bash
dig +short argo.ukkiee.dev
dig +short test-web.ukkiee.dev
nslookup argo.ukkiee.dev
```

- [ ] `argo.ukkiee.dev` 응답 IP 가 Cloudflare anycast 범위
- [ ] `test-web.ukkiee.dev` 응답 IP 가 Cloudflare anycast 범위

### 6.4 서비스 라이브성

```bash
curl -I https://argo.ukkiee.dev -m 5
# HTTP/2 ... (Cloudflare edge 응답, Tailscale 미연결 시 403/451 가능하지만 Cloudflare edge 에서는 정상)

curl -I https://test-web.ukkiee.dev -m 5
# HTTP/2 200 OK (또는 라우트 상태에 따른 응답, 핵심은 Cloudflare edge 가 요청 수신)
```

- [ ] Cloudflare edge 응답 정상 (5xx 아님)

### 6.5 WAF 동작 검증 (선택)

의심스러우면 단일 테스트 (dev 브라우저에서):
- [ ] User-Agent 를 `python-requests/2.x` 로 보내서 test-web.ukkiee.dev 접근 시 Cloudflare 차단 페이지 확인 (block_malicious_ua rule)
- [ ] 한국 외 IP 에서 접근 시 managed challenge 확인 (geo_challenge_non_kr rule — 필요시 VPN 또는 proxy 로 테스트)

※ 운영 중단 위험 없는 범위에서만 시도. skip 가능.

### 6.6 커밋 및 PR

```bash
cd /Users/ukyi/homelab
git add terraform/
git status
# modified:   terraform/backend.tf 또는 provider.tf (version pin)
# modified:   terraform/dns.tf     (cloudflare_record → cloudflare_dns_record + moved block)
# modified:   terraform/cache.tf   (rules list 전환)
# modified:   terraform/waf.tf     (rules list 전환 × 2)
# modified:   terraform/.terraform.lock.hcl
# (apps.json, backend.tf backend 부분, variables.tf 는 변경 없음)

git diff --stat
git commit -m "chore(terraform): Cloudflare provider v4.52.7 → v5.18.0 migration

- cloudflare_record → cloudflare_dns_record (moved block)
- cloudflare_ruleset: block → nested attribute schema
- provider version: = 5.18.0 (precise pin, not ~>)
- lock.hcl updated

Migration verified: plan clean, dashboard unchanged, DNS resolving
"
```

- [ ] 커밋 작성 완료
- [ ] PR 생성 (원한다면)

---

## 7. 예상 다운타임 및 허용 창 적합성

### 7.1 다운타임 예산

| 항목 | 시간 | 영향 | 비고 |
|---|---|---|---|
| Edge 트래픽 (DNS 응답, WAF 적용) | **0 초** | 없음 | 시나리오 A/B (state 만 조작) |
| 시나리오 C 전체 re-import 중 | **0 초** | 없음 | state rm 은 CF API 호출 없음. 리소스는 CF 측에 계속 존재 |
| **단, destroy/recreate plan 을 apply 시** | 최대 **5분** | DNS 단절 | **apply 금지**. 섹션 4.2 참조 |

### 7.2 IaC 관리 공백

| 항목 | 시간 | 영향 | 대응 |
|---|---|---|---|
| Migration 작업 시간 | **4.5 ~ 6시간** | Terraform 으로 긴급 CF 수정 불가 | Dashboard 직수정은 migration 후 state 동기화 (plan 에서 drift 발견 → apply) |
| Dashboard 동기화 지연 | 수분 | 수동 변경이 migration state 와 충돌 | migration 종료 후 `terraform plan` 반드시 한 번 실행해 drift 정리 |

### 7.3 허용 창 적합성

`00_scope.md` 요구사항:
> - **Edge 트래픽 영향**: 없음
> - **terraform apply 창**: 실행 시 수 분 필요하나 트래픽 무관
> - **Drift 리스크 창**: v5 migration 중간에 state 불일치 발생 가능 — 이 창 동안 수동 Cloudflare dashboard 조작 금지

→ **적합**. 본 Runbook 의 모든 절차는 "다운타임 없음" 요구를 충족함. Drift 리스크 창은 섹션 4.3 에서 "Dashboard 수동 변경 금지" 로 통제.

---

## 8. Known Gotchas

### 8.1 v5.1 ~ v5.4 경유 금지 — v5.18 직접 pin

- v5.1.0 ~ v5.4.0 기간에 `http_request_cache_settings` phase + `set_cache_settings` action 조합이 "Plugin did not respond" 크래시 (GitHub Issue #5599)
- 홈랩 `cloudflare_ruleset.cache_rules` 가 정확히 이 패턴
- v5.8.2 이후 해결. v5.18 에서는 정상
- **조치**: `version = "= 5.18.0"` 정확 pin. 중간 버전 stepping 금지

### 8.2 `~> 5.18` 금지

- `~>` 는 5.x 마이너 업데이트 허용 → v5.19, v5.20 등이 떠오르면 자동 갱신
- v5.x 마이너에 breaking change 빈발 (v5.4, v5.6, v5.13)
- **조치**: 반드시 `= 5.18.0` 정확 pin. `~> 5.18` 또는 `~> 5.0` 금지

### 8.3 Renovate CF provider v5.x auto-merge 제외 필요

- Renovate 가 v5.18.0 → v5.19.0 자동 PR 생성 + auto-merge 하면 예상치 못한 regression
- **조치**: Renovate 설정 (`.github/renovate.json` 또는 `renovate.json`) 에 cloudflare provider 예외 추가:
  ```json
  {
    "packageRules": [
      {
        "matchDatasources": ["terraform-provider"],
        "matchPackageNames": ["cloudflare/cloudflare"],
        "automerge": false,
        "labels": ["manual-review", "cloudflare-provider"]
      }
    ]
  }
  ```
- **이 Runbook 의 scope 는 아님**. 후속 별건 PR. Renovate 설정이 없으면 더 문제 아니고, 있으면 별건으로 조치.

### 8.4 Ruleset recurring drift 가능성

- v5.0 ~ v5.8 시기 `cloudflare_ruleset` 의 `preserve_duplicates`, `raw_response_fields`, 특정 `action_parameters` 필드에서 반복 drift 보고
- v5.18 에서 대부분 해결되었으나 일부 잔존 가능
- **조치**:
  1. migration 직후 `terraform plan` 3~5회 반복 실행
  2. 같은 drift 가 3회 연속 나오면 HCL 을 v5 정확 schema 로 재조정
  3. 그래도 안 되면 임시 `lifecycle { ignore_changes = [...] }`. 근본 해결은 v5.19+ 에서 재검토

### 8.5 `cloudflare_r2_bucket_lifecycle` 는 import 미지원

- Phase 5 에서 R2 lifecycle 추가 시 **처음부터 Terraform 으로만** 생성
- 이미 Cloudflare Dashboard 에서 lifecycle rule 을 수동 추가했다면, Terraform 도입 전 Dashboard 에서 제거 후 Terraform 으로 재생성
- CORS (`cloudflare_r2_bucket_cors`) 도 동일 제약

### 8.6 R2 API token 권한 추가는 Dashboard 수동

- Terraform 으로 API token 자체를 관리하지 않음 (`cloudflare_api_token` 미사용)
- R2 리소스 추가 전 Cloudflare Dashboard > My Profile > API Tokens > (현재 token edit) > permissions 에 "Workers R2 Storage:Edit" (Account scope) 추가 필수
- 권한 누락 시 Phase 5 apply 에서 `403 Forbidden` 에러

### 8.7 `cloudflare_dns_record` 의 `name` zone-relative 동작 호환성

- 홈랩 `dns.tf` 는 `name = each.value.subdomain` (값: "argo", "test-web" — zone-relative)
- v5 공식 문서: "FQDN required". 그러나 `zone_id` 와 함께 쓰면 자동 확장 가능성 있음 (공식 확인 필요)
- **테스트 권장**: staging/테스트 zone 에서 `name = "test-cname"` + `zone_id` 조합 apply 해서 확인
- **대안 (안전)**: 명시적 FQDN 으로 전환:
  ```hcl
  name = "${each.value.subdomain}.${var.domain}"
  ```
- 이 경우 migration 중 플랜에 "update in-place" 가 `name` 필드에서 발생. 값이 동일 FQDN 이면 drift 아님
- **판단 분기**:
  - Phase 3 plan 에서 `name` 관련 drift/에러가 나면 → 명시적 FQDN 으로 전환 후 재시도
  - Plan 통과하면 → 그대로 유지

### 8.8 for_each DNS record 의 state key escape

- bash 에서 `terraform state rm 'cloudflare_dns_record.apps["argocd"]'` 실행 시 따옴표 중첩 주의
- single quote (`'...'`) 안에 double quote (`"..."`) 넣는 방식 필수
- zsh 에서도 동일. fish 등 다른 쉘 쓰면 escape 규칙 다름 → bash/zsh 사용 권장

### 8.9 `terraform state push -force` 의 serial 체크

- 롤백 시 로컬 backup 을 state push 할 때 serial 이 현재보다 낮으면 reject
- `-force` 플래그로 덮어쓰기 가능하나 R2 versioning 이 더 안전한 1차 경로
- R2 versioning 복원 → Terraform state push 순서 권장

### 8.10 backend.tf endpoint 변수화

- backend `endpoint` 는 `backend.tf` 파일에 하드코딩되어 있지 않음 (line 19 주석: "endpoint는 terraform init -backend-config으로 주입")
- migration 중 `terraform init -upgrade` 시에도 endpoint config 를 누락하면 backend 연결 실패 → 평소 사용하는 init 스크립트 또는 `.terraformrc` 방식 그대로 유지

---

## 9. 에스컬레이션

이 Runbook 으로 해결 안 되면:

### 9.1 확인할 문서
- Breaking change 세부: `/Users/ukyi/homelab/_workspace/01_breaking_changes.md`
- 홈랩 영향 분석 (이 Runbook 과 크로스체크): `/Users/ukyi/homelab/_workspace/02_impact_analysis.md`
- 공식 upgrade guide: https://github.com/cloudflare/terraform-provider-cloudflare/blob/main/docs/guides/version-5-upgrade.md
- Migration Ready 리소스 목록 (Issue #6237): https://github.com/cloudflare/terraform-provider-cloudflare/issues/6237

### 9.2 확인할 시스템
- Cloudflare Dashboard: https://dash.cloudflare.com → ukkiee.dev
- R2 Dashboard: https://dash.cloudflare.com → R2 → ukkiee-terraform-state
- GitHub Issues (검색어 예시):
  - `"no schema available" cloudflare_record` (Issue #4982 계열)
  - `cloudflare_ruleset drift v5`
  - `tf-migrate` (모듈 호환성 등)

### 9.3 수동 개입 필요 시
- **state 손상 / 복구 불가**: R2 versioning 에서 가장 오래된 버전까지 되돌려 보고, 그래도 안 되면 `/Users/ukyi/homelab/_workspace/backup-*.tfstate` 로컬 백업 push
- **Cloudflare API rate limit**: 연속 import 시 rate limit 가능 (1200 req / 5min). 하나씩 여유 두고 import
- **v5 regression 의심**: GitHub Issue 검색 → 해당 안 보이면 새 이슈로 reproducer 함께 리포트 후 v5.17 로 다운그레이드 검토 (v5.17 도 stabilized)

### 9.4 v5.19 GA 이후 재평가

- GA 예상: 2026-04-20 주
- 재평가 항목:
  - Automatic state upgrader 61 리소스 지원 확장 → 수동 state rm/import 불필요해질 수 있음
  - v5.19.x 안정성 (beta 기간 동안 regression 보고 수)
- 본 runbook 의 `= 5.18.0` pin 을 `= 5.19.x` 로 갱신할지 별건 PR 로 검토

---

## 10. 관련 문서

- [PostgreSQL Helm Upgrade Runbook](../postgresql-helm-upgrade.md) — 동일한 "Helm 에서 외부 state/secret 과 상호작용하는 업그레이드" 패턴
- [Disaster Recovery](../../disaster-recovery.md) — 재해 복구 절차 일반. 이 runbook 의 롤백이 실패한 최악의 경우 참조
- Scope: `_workspace/00_scope.md`
- Breaking changes 전수: `_workspace/01_breaking_changes.md`
- Impact analysis: `_workspace/02_impact_analysis.md`
- Terraform 파일:
  - `terraform/provider.tf`
  - `terraform/backend.tf`
  - `terraform/dns.tf`
  - `terraform/cache.tf`
  - `terraform/waf.tf`
  - `terraform/variables.tf`
  - `terraform/apps.json`
  - `terraform/.terraform.lock.hcl`
- 공식 리소스:
  - Upgrade guide: https://github.com/cloudflare/terraform-provider-cloudflare/blob/main/docs/guides/version-5-upgrade.md
  - `cloudflare_dns_record` schema: https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/dns_record
  - `cloudflare_ruleset` schema: https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/ruleset
  - `cloudflare_r2_bucket` schema: https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/r2_bucket
  - `cloudflare_r2_bucket_lifecycle` schema: https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/r2_bucket_lifecycle
  - tf-migrate: https://github.com/cloudflare/tf-migrate
  - v5.18.0 release: https://github.com/cloudflare/terraform-provider-cloudflare/releases/tag/v5.18.0

---

## 부록 A. 빠른 재개용 요약 (2~3시간 후 돌아왔을 때)

현재 위치 확인:

```bash
cd /Users/ukyi/homelab
git branch --show-current
# feat/cloudflare-v5 이면 진행 중

cd terraform
grep 'version' .terraform.lock.hcl | head -2
# "4.52.7"  → Phase 1 이전 (아직 시작 안 함)
# "5.18.0"  → Phase 3 이후

terraform state list | head -5
# cloudflare_record.apps[...]   → v4 state 상태 (Phase 1~2 중)
# cloudflare_dns_record.apps[...] → v5 state 상태 (Phase 3~4 중)
```

다음 액션 판단:

| 상황 | 다음 단계 |
|---|---|
| `4.52.7` + state 에 `cloudflare_record` | Phase 2 (tf-migrate / 수동 편집) |
| `5.18.0` + state 에 `cloudflare_record` (rename 아직 안 됨) | Phase 3 state rm + import |
| `5.18.0` + state 에 `cloudflare_dns_record` + plan 에 drift 있음 | Phase 3 drift 해결 반복 |
| `5.18.0` + plan "No changes" | Phase 4 검증 및 커밋 |

이 runbook 의 각 Phase 체크포인트로 돌아가 재개.
