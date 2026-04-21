# app-starter 단순화 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** app-starter 의 `create-app.yml` workflow 입력을 2개 (service-name, subdomain) 로 축소하고, 나머지 설정 (type · health · icon · description · database) 을 `services/<svc>/.app-config.yml` 로 이관한다. 타입별 포트 통합 + static=caddy 지원 + CNPG 기본 사용 + DB 모드 자동 판단.

**Architecture:**
`.app-config.yml` 을 single source of truth 로 전환. **caller (앱 레포) 가 자신의 `.app-config.yml` 을 읽어 `workflow_call input` 으로 전달**하는 pattern 을 채택 (리뷰 C1 반영 — 기존 GitHub App token 이 `repositories: homelab` 으로 제한되어 homelab 에서 앱 레포 직접 fetch 불가). 이후 `.app-config.yml` 변경 시 `_sync-app-config.yml` 이 health/icon/description 재반영, database 블록은 immutable guard 로 drift 감지.

**Tech Stack:** GitHub Actions (workflow_call + composite), yq v4, kubeseal, CNPG operator, Kustomize, caddy (static 타입)

---

## 리뷰 반영 이력 (2026-04-21)

`docs/plans/2026-04-21-app-starter-simplification-review.md` 리뷰 결과 **Critical 4건 + Medium 5건 + Minor 6건** 반영.

| ID | 항목 | 반영 위치 |
|----|------|-----------|
| C1 | 앱 레포 토큰 문제 | §0 D4 추가, Architecture 재설계, Phase 2 전면 수정 |
| C2 | Docker COPY `../../` 위반 | §Phase 5.1 context=루트로 수정 |
| C3 | 입력 축소 시 caller 파손 | §Phase 3 deprecation-first, Phase 3b cleanup 분리 |
| C4 | `project: default` vs `apps` | Phase 2 에 `project: apps` 전환 step 추가 |
| M1 | database immutability 누락 | Phase 7 에 `_sync-app-config.yml` guard step 추가 |
| M2 | DB reference 모드 미구현 | Phase 6 scope 확대 + 시간 2h → 4h |
| M3 | 포트 통합 검증 근거 없음 | §3 에 실측 증거 (static 앱 0개, 2026-04-21 확인) 기록 |
| M4 | yq 설치 타이밍 | Phase 2 에 명시적 순서 도표 추가 |
| M5 | Phase 2 → 4/5 호환성 갭 | Phase 2 에 hybrid fallback (config 우선, inputs 대체) |
| m1-m6 | Minor | 각 섹션에서 수정 |

---

## 0. 결정 사항 (확정 — 2026-04-21)

| ID | 결정 | 비고 |
|----|------|------|
| **D1** | ✅ 옵션 A — 3000 통합 | 기존 web 앱 영향 0 (실측 확인) |
| **D2** | ✅ 옵션 A 변형 — `type` 필드는 worker 일 때만 명시. web/static 은 기본값 = HTTP service | setup-app 관점에서 web/static 차이 없음 (D1 통합 후 포트·매니페스트 동일) |
| **D3** | ✅ 옵션 A — name+ref 이분법 | 명시성 우선, 자동 판단 위험 회피 |
| **D4** | ✅ 옵션 A — Caller 측 파싱 (config-yaml input 추가) | 토큰 권한 변경 0, 최소 권한 원칙 유지 |

### D1. 통합 포트 번호 — 확정: 3000

| 옵션 | 장점 | 단점 |
|------|------|------|
| **3000** (권장) | Node.js 관례 일치, web 기존값 유지 | static caddy 가 기본 80 대신 3000 리슨 필요 (Caddyfile 에 명시) |
| 8080 | static 기존값, caddy 기본 근접 | web 앱 PORT env 대응 필요 |

### D2. worker 타입 처리 — 확정: 옵션 A 변형 (`type` 은 worker 일 때만 명시)

**기본 원칙**:
- `.app-config.yml` 에 `type` 필드 없음 → **HTTP service** (web 또는 static, Dockerfile 이 결정)
- `.app-config.yml.type: worker` → worker (포트·IngressRoute·Homepage annotation 모두 skip)
- web/static 구분은 setup-app 관점에서 무의미 (D1 통합 후 포트·매니페스트 동일)
- web/static 차이 = Dockerfile 내용만 (Node.js 직접 실행 vs caddy 정적 서빙) — 사용자가 직접 작성

**검증 로직**:
| `.app-config.yml.type` 값 | 동작 |
|---------------------------|------|
| (없음) 또는 빈 문자열 | HTTP service (기본) |
| `worker` | worker |
| `web` 또는 `static` | `::warning::type: <값> 은 deprecated. type 필드 생략 시 HTTP service 기본` + HTTP service 처리 |
| 기타 | `::error::invalid type` + 종료 |

### D3. DB owner vs reference 자동 판단 규칙 — **권장: 옵션 A**

| 옵션 | 스키마 | 판단 로직 |
|------|--------|-----------|
| **A. name+ref 이분법** (권장) | `database: {name: <db>}` (owner) · `database: {ref: <svc>}` (reference) | 사용자가 의도를 직접 선언. 명시적. |
| B. 자동 스캔 | `database: {name: <db>}` 만 | composite 가 homelab `manifests/apps/<project>/` 스캔, 같은 name 을 가진 owner 가 있으면 reference, 없으면 owner. 자동이지만 race condition · 이름 충돌 가능. |

**권장 이유**: 옵션 B 는 "순서 의존" 문제. 두 서비스가 동시에 `name: foo` 선언 시 어느 쪽이 owner 될지 불명확. 옵션 A 는 사용자가 owner 를 명시적으로 선언 (`name`) 하고, 참조자는 `ref: <owner-svc>` 로 가리킨다.

### D4. 앱 레포 `.app-config.yml` 전달 방식 — **권장: 옵션 A (caller 측 파싱)** (리뷰 C1)

현재 GitHub App token 이 `repositories: homelab` 으로 엄격 제한되어 homelab composite 에서 앱 레포 `.app-config.yml` 을 fetch 불가 (`403 Forbidden`).

| 옵션 | 설명 | 트레이드오프 |
|------|------|-------------|
| **A. Caller 측 파싱** (권장) | 앱 레포 caller workflow 가 `secrets.GITHUB_TOKEN` 으로 `.app-config.yml` 을 읽어 workflow_call input `config-yaml` 로 문자열 전달. homelab 에서 yq 로 파싱. | 입력 1개 추가 (service-name · subdomain · config-yaml = 3개). GitHub App token 범위 변경 불필요. 가장 안전. |
| B. App installation 에 `<app-name>` 추가 | 토큰 발급 시 `repositories: [homelab, <app-name>]` 로 동적 확장 | App installation 에 모든 derived 앱 레포 자동 포함 필요 (org-level installation 이 'All repositories' 여야 가능). 현재 상태 확인 필요. |
| C. Installation 전체 범위 토큰 | `repositories` 필드 제거 | 보안 범위 확장, 최소 권한 원칙 위배. ArgoCD·RBAC 와 독립된 다른 경로에서 homelab 외 레포에도 write 가능 → NO. |

**권장 이유**: 옵션 A 는 caller 측에서 단순 `cat services/<svc>/.app-config.yml` 로 읽어 output 으로 전달. homelab 은 문자열 하나만 받아 yq 로 파싱. 토큰 전략 변경 불필요, 기존 installation 유지.

**caller 측 구현 예시** (app-starter create-app.yml):
```yaml
jobs:
  read-config:
    runs-on: ubuntu-latest
    outputs:
      config: ${{ steps.cat.outputs.config }}
    steps:
      - uses: actions/checkout@v4
      - id: cat
        run: |
          CONFIG_PATH="services/${{ inputs.service-name }}/.app-config.yml"
          if [ ! -f "$CONFIG_PATH" ]; then
            echo "::error::$CONFIG_PATH not found"; exit 1
          fi
          # GITHUB_OUTPUT 은 multiline 을 delimiter 구문으로 지원
          {
            echo "config<<__EOF__"
            cat "$CONFIG_PATH"
            echo "__EOF__"
          } >> "$GITHUB_OUTPUT"

  create:
    needs: read-config
    uses: ukkiee-dev/homelab/.github/workflows/_create-app.yml@main
    with:
      app-name: ${{ github.event.repository.name }}
      service-name: ${{ inputs.service-name }}
      subdomain: ${{ inputs.subdomain }}
      config-yaml: ${{ needs.read-config.outputs.config }}
    secrets: inherit
```

### 4 결정 모두 확정 (2026-04-21)

이 plan 은 **D1=3000, D2=worker 만 type 명시, D3=name+ref 이분법, D4=caller 측 파싱** 기준으로 작성. Phase 1 착수 가능.

---

## 1. 범위 & 영향 범위

### 변경 대상 (Phase 별)

| 레포 | 파일 | 변경되는 Phase |
|------|------|---------------|
| `ukkiee-dev/app-starter` | `services/_template-web/.app-config.yml`, `_template-worker/.app-config.yml` (신규) | Phase 1 |
| `ukkiee-dev/app-starter` | `services/_template-static/{Dockerfile,Caddyfile,.app-config.yml,package.json,index.html}` (신규) | Phase 5 |
| `ukkiee-dev/app-starter` | `.github/workflows/create-app.yml` (간소화 + config-yaml output) | Phase 4 |
| `ukkiee-dev/app-starter` | `README.md` (스키마·템플릿 설명) | Phase 1, 5, 7 |
| `ukkiee-dev/homelab` | `.github/workflows/_create-app.yml` (입력 schema 변경 — deprecation-first) | Phase 3, 3b |
| `ukkiee-dev/homelab` | `.github/actions/setup-app/action.yml` (yq 앞당김 + `.app-config.yml` 파싱 + hybrid fallback + project=apps) | Phase 2 |
| `ukkiee-dev/homelab` | `.github/actions/setup-app/database/action.yml` (reference 모드 완전 구현) | Phase 6 |
| `ukkiee-dev/homelab` | `.github/workflows/_sync-app-config.yml` (database immutability guard) | Phase 7 |
| `ukkiee-dev/homelab` | `.github/workflows/_teardown.yml` (config-yaml 기반 DB 정리 확인) | Phase 7 |
| `ukkiee-dev/homelab` | `docs/runbooks/postgresql/cnpg-new-project.md` (`.app-config.yml` 방식 반영) | Phase 7 |
| `ukkiee-dev/homelab` | `docs/disaster-recovery.md` (app-starter 레퍼런스 갱신) | Phase 7 |
| `ukkiee-dev/test-web` | `.github/workflows/create-app.yml`, `.app-config.yml` (type 추가) | Phase 4 |
| `ukkiee-dev/pokopia-wiki` | `services/<svc>/.app-config.yml` (사용자 수동 PR) | Phase 7 |

### 영향 없는 파일 (기존 유지)

- `.github/templates/cnpg/*.yaml.tpl` — 매니페스트 템플릿 그대로.
- CNPG 관련 Runbook (cnpg-upgrade, cnpg-webhook-deadlock-escape, cnpg-pitr-restore, cnpg-dr-new-namespace), memory, AppProject — 변경 없음.
- `setup-app/action.yml` 의 AppProject destinations 자동 등록 (라인 928–954, PR #18) — 이미 구현됨, 재사용.
- `setup-app/action.yml` 의 ignoreDifferences 자동 주입 (라인 868–919) — 이미 구현됨, 재사용.

---

## 2. 새 스키마: `.app-config.yml`

### 2.1 위치

- **flat 앱** (단일 서비스 레포, 예: test-web): **루트 `.app-config.yml`** (기존 그대로)
- **monorepo 앱** (pnpm workspace, 예: app-starter 기반): **`services/<svc>/.app-config.yml`** (기존 그대로)

build.yml 의 경로 감지는 이미 `services/<svc>/.app-config.yml` 기준. 변경 불필요.

### 2.2 전체 스키마 (주석 포함 — 템플릿으로 사용)

#### 2.2.1 HTTP service (web 또는 static — 기본)

```yaml
# 앱/서비스 설정 — 변경 후 push 하면 _sync-app-config.yml 이 homelab 에 반영
#
# type 필드 생략 (또는 빈 값) = HTTP service 기본
# Dockerfile 이 web (Node.js 직접 실행) vs static (caddy + 정적 빌드) 결정
# setup-app 관점에서는 동일 (포트 3000, IngressRoute, Service, Homepage 모두 생성)

# 헬스체크 경로
health: /health

# Homepage 표시 (비우면 create-app 시 기본값 유지)
icon: mdi-application   # mdi-*: materialdesignicons.com | si-*: simpleicons.org | 이름.png: github.com/walkxcode/dashboard-icons
description: ""         # 빈 문자열이면 repo description 사용

# DB 설정 (주석 해제 시 CNPG 클러스터 생성/연결)
#
# 옵션 1 — 신규 DB 소유자 (owner):
# database:
#   name: myapp_db     # DB 이름 (PostgreSQL 규칙: 소문자·숫자·_, 63자 이하)
#   # storage: 10Gi    # PVC 크기 (기본 10Gi, local-path 는 resize 불가)
#
# 옵션 2 — 다른 서비스의 DB 참조 (reference):
# database:
#   ref: api           # 같은 project 내 owner 서비스 이름 (name 대신 ref 사용)
#
# name · ref 는 상호 배타. 둘 중 하나만 지정.
# database 블록 자체가 없으면 DB 없음 (기존 앱 동작).
```

#### 2.2.2 Worker service (포트·HTTP 없음)

```yaml
# 백그라운드 서비스 (cron, 메시지 큐 consumer 등)
type: worker        # worker 일 때만 명시. 포트·IngressRoute·Homepage annotation 모두 skip.

# health/icon/description 작성해도 무시됨 (worker 는 HTTP 노출 없음)

# DB 사용 가능 (worker 도 DB 연결 OK)
# database:
#   ref: api          # 보통 worker 는 같은 project 의 owner DB 를 참조
```

### 2.3 스키마 검증 규칙 (D2 변형 반영)

| 필드 | 타입 | 필수 | 기본값 | 검증 |
|------|------|------|--------|------|
| `type` | string | ❌ | "" (= HTTP service) | 빈 값(=HTTP) 또는 `worker` 만 허용 |
| `health` | string | ❌ (HTTP service 만 사용) | `/health` | `/` 로 시작 |
| `icon` | string | ❌ | `mdi-application` | — |
| `description` | string | ❌ | repo 의 description (workflow 에서 주입) | — |
| `database` | object | ❌ | 없음 | `name` 또는 `ref` 중 하나만 |
| `database.name` | string | ❌ | — | PostgreSQL identifier 규칙 (소문자·숫자·_) |
| `database.ref` | string | ❌ | — | 같은 project 내 존재하는 service-name |
| `database.storage` | string | ❌ | `10Gi` | Kubernetes storage quantity (name 과만 조합) |

### 2.4 경고/오류 케이스 (파싱 단계)

| 조건 | 심각도 | 메시지 |
|------|--------|--------|
| `type: web` 또는 `type: static` | `::warning::` | `type: <값> 은 deprecated. type 필드 생략 시 HTTP service 기본` (계속 진행) |
| `type: worker` + `health` 지정 | `::warning::` | `worker 타입에서는 health 가 무시됩니다` (계속 진행) |
| `type: worker` + `icon`/`description` 지정 | `::warning::` | `worker 타입은 Homepage 에 표시되지 않아 icon/description 이 사용되지 않습니다` (계속 진행) |
| `type` 가 빈 값/worker/web/static 외 값 | `::error::` | `invalid type: <값>. type 필드 생략 (HTTP) 또는 'worker' 만 허용` + 종료 |
| `database.name` + `database.ref` 동시 지정 | `::error::` | `database.name 과 database.ref 는 상호 배타` + 종료 |

---

## 3. 새 스키마: `create-app.yml` (app-starter)

### 3.0 입력 개수 표기 기준 (리뷰 m1)

| 층위 | 현재 | 목표 | 비고 |
|------|------|------|------|
| **app-starter caller** (workflow_dispatch 입력) | 12 | **2** (service-name, subdomain) | 사용자 UX |
| **test-web caller** (workflow_dispatch 입력) | 2 | **1-2** (subdomain, 필요시 service-name) | flat 앱 |
| **homelab reusable** (`_create-app.yml` workflow_call) | 13 | **4** (app-name, service-name, subdomain, config-yaml) | 리뷰 D4 반영 config-yaml 추가 |

### 3.1 포트 통합 (D1=3000) 검증 근거 — 리뷰 M3

2026-04-21 실측 (변경 착수 전):
```bash
$ grep -rn "containerPort: 8080" manifests/apps/   # 0 matches
$ grep -rn "app.kubernetes.io/component: static" manifests/apps/   # 0 matches
```

**결론**: 현재 `type: static` 배포 앱 0개. 포트 3000 통합으로 기존 앱 영향 없음. 신규 static 앱은 Caddyfile 이 3000 리슨으로 작성 (Phase 5.2).

### 3.2 app-starter `create-app.yml` (caller, workflow_dispatch 입력 2개)

```yaml
name: Create App

on:
  workflow_dispatch:
    inputs:
      service-name:
        description: "모노레포 서비스 이름 (services/<name>). pnpm workspace 구조와 일치."
        required: true
        type: string
      subdomain:
        description: "서브도메인 (비우면 <repo>-<service>). DNS 레코드에 반영."
        required: false
        type: string
        default: ""

permissions:
  contents: write

concurrency:
  group: homelab-terraform
  cancel-in-progress: false

jobs:
  # (리뷰 D4) 앱 레포 .app-config.yml 을 읽어 homelab 에 전달
  read-config:
    if: github.repository != 'ukkiee-dev/app-starter'
    runs-on: ubuntu-latest
    outputs:
      config: ${{ steps.cat.outputs.config }}
    steps:
      - uses: actions/checkout@v4
      - id: cat
        env:
          SERVICE: ${{ inputs.service-name }}
        run: |
          set -euo pipefail
          CONFIG_PATH="services/$SERVICE/.app-config.yml"
          if [ ! -f "$CONFIG_PATH" ]; then
            echo "::error::$CONFIG_PATH not found. 서비스 템플릿에 .app-config.yml 을 추가하세요."
            exit 1
          fi
          {
            echo "config<<__EOF__"
            cat "$CONFIG_PATH"
            echo "__EOF__"
          } >> "$GITHUB_OUTPUT"

  create:
    needs: read-config
    uses: ukkiee-dev/homelab/.github/workflows/_create-app.yml@main
    with:
      app-name: ${{ github.event.repository.name }}
      service-name: ${{ inputs.service-name }}
      subdomain: ${{ inputs.subdomain }}
      config-yaml: ${{ needs.read-config.outputs.config }}
    secrets: inherit
```

### 3.2 제거되는 입력 (12개 → 2개)

| 제거 | 새 소스 |
|------|---------|
| `app-type` | `.app-config.yml` `type` (composite 가 앱 레포 checkout 후 yq 로 읽음) |
| `app-health` | `.app-config.yml` `health` |
| `default-icon` | `.app-config.yml` `icon` (없으면 `mdi-application` 내장 기본) |
| `database-enabled` | `.app-config.yml` `database` 블록 존재 여부 |
| `database-mode` | `database.name`(owner) vs `database.ref`(reference) 로 자동 판단 |
| `database-name` | `.app-config.yml` `database.name` |
| `database-role` | 자동 기본값 (service-name) — override 필요 시 추후 확장 |
| `database-ref` | `.app-config.yml` `database.ref` |
| `database-storage` | `.app-config.yml` `database.storage` |
| `database-pg-image-tag` | 내부 기본값 (setup-app 의 default input) |

### 3.3 homelab `_create-app.yml` 입력 축소 + deprecation (C3 완화)

**Phase 3 단계**: 기존 입력을 `required: false` + default 로 남기고 silently ignore. 신규 입력 `config-yaml` 추가.

```yaml
on:
  workflow_call:
    inputs:
      # 신규 (필수)
      app-name: { required: true, type: string }
      service-name: { required: false, type: string, default: "" }
      subdomain: { required: false, type: string, default: "" }
      config-yaml: { required: false, type: string, default: "" }  # 리뷰 D4
      # Deprecated (Phase 3b 에서 제거) — caller 호환성 유지용
      app-type: { required: false, type: string, default: "" }
      app-health: { required: false, type: string, default: "" }
      default-icon: { required: false, type: string, default: "" }
      database-enabled: { required: false, type: string, default: "false" }
      database-mode: { required: false, type: string, default: "none" }
      database-name: { required: false, type: string, default: "" }
      database-role: { required: false, type: string, default: "" }
      database-ref: { required: false, type: string, default: "" }
      database-storage: { required: false, type: string, default: "10Gi" }
      database-pg-image-tag: { required: false, type: string, default: "16.13-standard-trixie" }
    secrets:
      APP_ID: { required: true }
      APP_PRIVATE_KEY: { required: true }
      TF_CLOUDFLARE_TOKEN: { required: true }
      TF_ZONE_ID: { required: true }
      TF_TUNNEL_ID: { required: true }
      TF_ACCOUNT_ID: { required: true }
      R2_ACCESS_KEY_ID: { required: true }
      R2_SECRET_ACCESS_KEY: { required: true }
      TF_DOMAIN: { required: false }
      TELEGRAM_BOT_TOKEN: { required: false }
      TELEGRAM_CHAT_ID: { required: false }
```

- Phase 3 (deprecation): 13 + 1 = **14 입력** (기존 13 + config-yaml). caller 호환성 100%.
- Phase 3b (cleanup, 모든 caller 업데이트 후): **4 입력** (app-name, service-name, subdomain, config-yaml). deprecated 제거.

이 2-단계 migration 이 리뷰 C3 해결책.

---

## 4. Phase 분할

### Phase 순서 (의존성 그래프 — 리뷰 반영)

```
Phase 1 (.app-config.yml 스키마 확정 + 템플릿)
   ↓
Phase 2 (setup-app composite: yq 앞당김 + config-yaml 파싱 + hybrid fallback + project=apps)
   ↓
Phase 3 (_create-app.yml: config-yaml 입력 추가, 기존 입력 deprecated 유지)
   ↓
Phase 4 (create-app.yml caller 간소화 — app-starter + test-web)
   ↓                           ↓
Phase 5 (static caddy 템플릿)   Phase 6 (DB reference 모드 완전 구현)
   ↓                           ↓
Phase 7 (마이그레이션 + _sync immutability guard + teardown + 문서)
   ↓
Phase 3b (deprecated 입력 cleanup — 모든 caller 업데이트 확인 후)
```

**중요**: Phase 3b 는 Phase 4/5/6/7 에서 **모든 caller 가 새 포맷으로 업데이트되었음을 확인한 후** 실행. 이를 통해 C3 (호환성 파손) 방지.

---

### Phase 1: `.app-config.yml` 스키마 확정 + 템플릿 (D2 변형 반영)

**Files:**
- Create: app-starter `services/_template-web/.app-config.yml` (HTTP service, **type 필드 없음**)
- Create: app-starter `services/_template-static/.app-config.yml` (HTTP service, **type 필드 없음**)
- Create: app-starter `services/_template-worker/.app-config.yml` (`type: worker`)
- Modify: app-starter `README.md` (스키마 설명 추가)

**Step 1.1: `_template-web/.app-config.yml`** (§2.2.1 형식)

```yaml
# Web service (Node.js — Dockerfile 이 결정)
# type 필드 없음 = HTTP service 기본 (포트 3000, IngressRoute, Service, Homepage 모두 자동)

health: /health
icon: mdi-application
description: ""

# database:
#   name: myapp_db     # owner (신규 DB)
# OR:
#   ref: api           # reference (다른 서비스의 DB 참조)
```

**Step 1.2: `_template-static/.app-config.yml`** (§2.2.1 형식, web 과 거의 동일)

```yaml
# Static service (caddy + 정적 빌드 — Dockerfile 이 결정)
# type 필드 없음 = HTTP service 기본 (web 과 동일 처리, 차이는 Dockerfile 만)

health: /health
icon: mdi-web
description: ""

# database 블록 동일 (HTTP service 도 DB 사용 가능)
```

**Step 1.3: `_template-worker/.app-config.yml`** (§2.2.2 형식)

```yaml
# Worker service (백그라운드 처리 — 포트 없음)
type: worker

# health/icon/description 작성해도 무시됨

# database:
#   ref: api           # 보통 worker 는 owner 의 DB 참조
```

**Step 1.4: README 업데이트**

`.app-config.yml` 스키마 설명 + 두 가지 사용 패턴 (HTTP service vs worker) + DB 섹션.

**Step 1.5: PR 1 생성 (app-starter)**
- title: `docs: .app-config.yml 스키마 확장 (worker type + database)`
- 이 PR 만 머지해도 동작 변경 없음 (템플릿 + README)

---

### Phase 2: setup-app composite — `config-yaml` 파싱 + hybrid fallback + type 통합 + project=apps

**Files:**
- Modify: `/Users/ukyi/homelab/.github/actions/setup-app/action.yml`

**설계 변경 (리뷰 반영)**:
- **리뷰 C1**: 앱 레포 checkout 제거, caller 가 전달한 `config-yaml` 문자열 파싱
- **리뷰 C4**: Application `project: default` → `project: apps`
- **리뷰 M4**: `Install yq` step 을 `Checkout homelab` 직후로 앞당김
- **리뷰 M5**: hybrid — config-yaml 우선, 없으면 `inputs.app-type`/`inputs.app-health` 등 deprecated inputs 로 fallback (caller 업데이트 갭 방어)

**설계 명시적 step 순서** (리뷰 M4 해결):

```
1. Checkout homelab       (기존)
2. Install yq             ← (M4) 여기로 앞당김
3. Parse config (새)      ← (C1) config-yaml input 파싱, hybrid fallback
4. Update apps.json       (기존, steps.config.outputs.type 사용)
5. Terraform Init/Plan/Apply (기존)
6. Add tunnel ingress     (기존)
7. Create manifests       (기존, steps.config.outputs.* 사용)
8. Create ArgoCD Application (기존, project: apps 로 변경)
9. Setup CNPG database (owner)    (기존 + 조건 변경)
10. Setup CNPG database (reference) (Phase 6 에서 추가)
11. Update AppProject destinations (기존)
12. Commit & Push         (기존)
```

**Step 2.1: yq 설치 앞당기기 (M4)**

action.yml 의 라인 136 `Install yq` step 을 **라인 44 `Checkout homelab` 직후** (Update apps.json 전) 로 이동.

**Step 2.2: `_create-app.yml` 입력에 `config-yaml` 추가** (Phase 3 의존)

Phase 3 에서 `_create-app.yml` 이 `config-yaml` 을 받아 setup-app 에 전달. Phase 2 는 setup-app 쪽만 수정 — 입력 추가:

```yaml
# setup-app/action.yml inputs 에 추가
config-yaml:
  required: false
  default: ""
  description: ".app-config.yml 내용 (caller 가 전달). 비어있으면 deprecated inputs 로 fallback."
```

**Step 2.3: `Parse config` step 추가 (C1 + M5 hybrid)**

```yaml
- name: Parse config (.app-config.yml 또는 deprecated inputs)
  id: config
  shell: bash
  env:
    CONFIG_YAML: ${{ inputs.config-yaml }}
    # deprecated inputs (hybrid fallback)
    IN_TYPE: ${{ inputs.type }}
    IN_HEALTH: ${{ inputs.health }}
    IN_ICON: ${{ inputs.icon }}
    IN_DESCRIPTION: ${{ inputs.description }}
    IN_DB_ENABLED: ${{ inputs.database-enabled }}
    IN_DB_MODE: ${{ inputs.database-mode }}
    IN_DB_NAME: ${{ inputs.database-name }}
    IN_DB_REF: ${{ inputs.database-ref }}
    IN_DB_STORAGE: ${{ inputs.database-storage }}
  run: |
    set -euo pipefail

    if [ -n "$CONFIG_YAML" ]; then
      echo "::notice::config-yaml 전달받음. .app-config.yml 우선 파싱"
      CONFIG_FILE=$(mktemp)
      echo "$CONFIG_YAML" > "$CONFIG_FILE"

      RAW_TYPE=$(yq '.type // ""' "$CONFIG_FILE")
      HEALTH=$(yq '.health // "/health"' "$CONFIG_FILE")
      ICON=$(yq '.icon // "mdi-application"' "$CONFIG_FILE")
      DESCRIPTION=$(yq '.description // ""' "$CONFIG_FILE")
      DB_NAME=$(yq '.database.name // ""' "$CONFIG_FILE")
      DB_REF=$(yq '.database.ref // ""' "$CONFIG_FILE")
      DB_STORAGE=$(yq '.database.storage // "10Gi"' "$CONFIG_FILE")
      rm -f "$CONFIG_FILE"
    else
      echo "::warning::config-yaml 비어있음. deprecated inputs 로 fallback (Phase 3b 이전 caller)"
      RAW_TYPE="${IN_TYPE:-}"
      HEALTH="${IN_HEALTH:-/health}"
      ICON="${IN_ICON:-mdi-application}"
      DESCRIPTION="$IN_DESCRIPTION"
      # 구 database-* 인풋 매핑
      if [ "$IN_DB_ENABLED" = "true" ]; then
        if [ "$IN_DB_MODE" = "owner" ]; then
          DB_NAME="$IN_DB_NAME"; DB_REF=""
        elif [ "$IN_DB_MODE" = "reference" ]; then
          DB_NAME=""; DB_REF="$IN_DB_REF"
        else
          DB_NAME=""; DB_REF=""
        fi
      else
        DB_NAME=""; DB_REF=""
      fi
      DB_STORAGE="${IN_DB_STORAGE:-10Gi}"
    fi

    # D2 변형: type 필드 → 내부 키 결정
    #   ""           → http  (HTTP service, 기본)
    #   "worker"     → worker
    #   "web"|"static" → http (deprecated warning + 동일 처리)
    #   기타         → error
    case "$RAW_TYPE" in
      "")     TYPE=http ;;
      worker) TYPE=worker ;;
      web|static)
        echo "::warning::type: $RAW_TYPE 은 deprecated. type 필드 생략 시 HTTP service 기본 (web/static 동일 처리)"
        TYPE=http
        ;;
      *)
        echo "::error::invalid type: $RAW_TYPE. type 필드 생략 (HTTP) 또는 'worker' 만 허용"
        exit 1
        ;;
    esac

    # 경고 케이스
    if [ "$TYPE" = "worker" ] && [ -n "$HEALTH" ] && [ "$HEALTH" != "/health" ]; then
      echo "::warning::type: worker 에서 health 값 무시됨 (IngressRoute 없음)"
    fi
    if [ "$TYPE" = "worker" ] && { [ -n "$ICON" ] && [ "$ICON" != "mdi-application" ] || [ -n "$DESCRIPTION" ]; }; then
      echo "::warning::type: worker 는 Homepage 에 표시되지 않아 icon/description 이 사용되지 않습니다"
    fi

    # DB 모드 결정 + 상호 배타 검증
    if [ -n "$DB_NAME" ] && [ -n "$DB_REF" ]; then
      echo "::error::database.name 과 database.ref 는 상호 배타"; exit 1
    elif [ -n "$DB_NAME" ]; then DB_MODE=owner
    elif [ -n "$DB_REF" ];  then DB_MODE=reference
    else                         DB_MODE=none
    fi

    # description fallback — 빈 문자열이면 repo description fetch (m5)
    if [ -z "$DESCRIPTION" ]; then
      TOKEN="${INPUTS_APP_TOKEN:-}"
      if [ -n "$TOKEN" ]; then
        DESCRIPTION=$(curl -s -H "Authorization: Bearer $TOKEN" \
          "https://api.github.com/repos/ukkiee-dev/${APP_NAME:-}" \
          | yq '.description // ""') || DESCRIPTION=""
      fi
      [ -z "$DESCRIPTION" ] && DESCRIPTION="${APP_NAME:-app}"
    fi

    {
      echo "type=$TYPE"
      echo "health=$HEALTH"
      echo "icon=$ICON"
      echo "description=$DESCRIPTION"
      echo "db-mode=$DB_MODE"
      echo "db-name=$DB_NAME"
      echo "db-ref=$DB_REF"
      echo "db-storage=$DB_STORAGE"
    } >> "$GITHUB_OUTPUT"
```

**Step 2.4: 포트 통합 + TYPE 분기 단순화 (D1 + D2 변형)**

기존 setup-app 의 `case "$TYPE" in` 블록 2곳 (flat 라인 ~158, monorepo 라인 ~450) 을 새 내부 키 (http/worker) 기준으로 재작성:

```bash
case "$TYPE" in
  http)  # D2 변형: web/static 모두 이 분기로 매핑됨
    PORT=3000
    MEMORY_REQUEST="128Mi"; MEMORY_LIMIT="256Mi"
    CPU_REQUEST="100m";     CPU_LIMIT="200m"
    [ -z "$HEALTH_PATH" ] && HEALTH_PATH="/health"
    ;;
  worker)
    PORT=0   # 포트·IngressRoute·Service 모두 skip
    MEMORY_REQUEST="128Mi"; MEMORY_LIMIT="256Mi"
    CPU_REQUEST="100m";     CPU_LIMIT="200m"
    ;;
  *)
    echo "::error::internal: unexpected TYPE=$TYPE"; exit 1
    ;;
esac
```

기존 `web)`, `static)` 분기 제거. 매니페스트 생성 step 의 `if [ "$TYPE" != "worker" ]` 조건은 그대로 (포트·IngressRoute·Homepage annotation 모두 worker 만 skip).

**Step 2.5: `inputs.type` / `inputs.health` / `inputs.icon` / `inputs.description` 참조 교체**

setup-app/action.yml 전역 검색 후 `steps.config.outputs.*` 로 치환. 현재 deprecated inputs 는 Parse config step 에서만 읽고 나머지 step 은 outputs 사용.

**Step 2.6: DB step 조건 변경 + reference 시범 추가 (실 구현은 Phase 6)**

```yaml
- name: Setup CNPG database (owner)
  if: steps.config.outputs.db-mode == 'owner' && inputs.service-name != ''
  uses: ukkiee-dev/homelab/.github/actions/setup-app/database@main
  with:
    mode: owner
    db-name: ${{ steps.config.outputs.db-name }}
    storage: ${{ steps.config.outputs.db-storage }}
    ...

# Phase 6 에서 reference step 추가 (M2)
- name: Setup CNPG database (reference)
  if: steps.config.outputs.db-mode == 'reference' && inputs.service-name != ''
  uses: ukkiee-dev/homelab/.github/actions/setup-app/database@main
  with:
    mode: reference
    ref-db: ${{ steps.config.outputs.db-ref }}
    ...
```

**Step 2.7: ArgoCD Application `project: apps` 전환 (C4)**

setup-app/action.yml 라인 764, 817 의 `project: default` 를 `project: apps` 로 변경. 기존 AppProject `apps` 에 destinations 자동 등록 로직 (라인 928–954) 이 이미 존재하므로 namespace 추가 자동 처리.

**영향 평가**: 기존 Application (adguard, homepage, uptime-kuma, postgresql, test-web, pokopia-wiki) 는 이미 `project: apps` (pokopia-wiki) 또는 수동 관리 상태. 자동 생성된 Application 만 default 였으므로 이 변경은 **신규 앱부터** 적용.

**Step 2.8: PR 2 생성 (homelab)**
- title: `feat(setup-app): config-yaml 파싱 + hybrid fallback + project=apps + yq 순서 앞당김`
- 리뷰 반영: C1 (caller 측 파싱), C4 (project apps), M4 (yq 순서), M5 (hybrid fallback)
- **중요**: 이 PR 머지 후 caller 들이 아직 업데이트 전이어도 hybrid fallback 으로 기존 동작 유지

---

### Phase 3: `_create-app.yml` — `config-yaml` 입력 추가, 기존 입력은 deprecated 유지 (C3)

**Files:**
- Modify: `/Users/ukyi/homelab/.github/workflows/_create-app.yml`

**Step 3.1: 신규 입력 `config-yaml` 추가**

§3.3 의 schema 적용. 기존 `app-type`/`app-health`/`default-icon`/`database-*` 모두 **`required: false` + 기본값** 으로 유지하여 caller 호환성 보존.

**중요**: 기존 `app-type` 은 `required: true` 였으나 deprecation 단계에서 `required: false` + `default: ""` 로 변경. setup-app 의 hybrid fallback 이 빈 문자열 → `web` default 처리.

**Step 3.2: setup-app 호출에 `config-yaml` 전달**

```yaml
- name: Run setup-app
  uses: ukkiee-dev/homelab/.github/actions/setup-app@main
  with:
    app-name: ${{ inputs.app-name }}
    service-name: ${{ inputs.service-name }}
    subdomain: ${{ steps.resolve.outputs.subdomain }}
    config-yaml: ${{ inputs.config-yaml }}
    # deprecated (Phase 3b 에서 제거)
    type: ${{ inputs.app-type }}
    health: ${{ inputs.app-health }}
    icon: ${{ inputs.default-icon }}
    description: ${{ steps.desc.outputs.description }}
    database-enabled: ${{ inputs.database-enabled }}
    database-mode: ${{ inputs.database-mode }}
    database-name: ${{ inputs.database-name }}
    database-role: ${{ inputs.database-role }}
    database-ref: ${{ inputs.database-ref }}
    database-storage: ${{ inputs.database-storage }}
    database-pg-image-tag: ${{ inputs.database-pg-image-tag }}
    # tf-* / r2-* / app-token / domain (변경 없음)
    ...
```

**Step 3.3: 기존 step 보존 확인**

`Validate app-name format`, `Generate token`, `Check repo exists in org`, `Check app does not already exist`, `Check GHCR image exists (pre-flight warning)`, `Resolve subdomain`, `Fetch description from GitHub repo` 모두 그대로 유지. 이들은 caller 변경과 독립.

**Step 3.4: PR 3 생성 (homelab, Phase 2 PR 머지 후)**
- title: `feat(workflow): _create-app.yml 에 config-yaml 입력 추가 (deprecation-first)`
- 기존 caller 모두 동작 유지, 신규 caller 는 config-yaml 사용 가능

---

### Phase 3b: deprecated 입력 cleanup (모든 caller 업데이트 후)

**Files:**
- Modify: `/Users/ukyi/homelab/.github/workflows/_create-app.yml`
- Modify: `/Users/ukyi/homelab/.github/actions/setup-app/action.yml`

**전제 조건** (착수 전 확인):
- [ ] app-starter `create-app.yml` 이 config-yaml 사용으로 업데이트됨 (Phase 4)
- [ ] test-web `create-app.yml` 이 config-yaml 사용으로 업데이트됨 (Phase 4)
- [ ] pokopia-wiki 가 새 caller 패턴으로 마이그레이션됨 (Phase 7)
- [ ] 다른 외부 caller 가 더 없음을 grep 으로 확인 (`gh search code "ukkiee-dev/homelab/.github/workflows/_create-app.yml@main"`)

**Step 3b.1: deprecated 입력 제거**

`_create-app.yml` 의 `app-type`/`app-health`/`default-icon`/`database-*` 입력 모두 제거. 최종 4개 입력 (app-name, service-name, subdomain, config-yaml).

**Step 3b.2: setup-app 의 hybrid fallback 분기 제거**

`Parse config` step 의 `if [ -n "$CONFIG_YAML" ]` 분기에서 else 블록 (deprecated inputs fallback) 제거. config-yaml 비어있으면 `::error::` 후 종료.

**Step 3b.3: setup-app inputs 정리**

`type`, `health`, `icon`, `description`, `database-enabled`, `database-mode`, `database-name`, `database-role`, `database-ref`, `database-storage`, `database-pg-image-tag` 모두 제거. 최종 setup-app inputs: app-name, service-name, subdomain, config-yaml, app-token, tf-*, r2-*, domain.

**Step 3b.4: PR 9 생성 (homelab)**
- title: `refactor(workflow): _create-app.yml + setup-app deprecated inputs 제거`
- 모든 caller 업데이트 확인 후 머지

---

### Phase 4: caller 간소화 (app-starter + test-web)

**Files:**
- Modify: app-starter `.github/workflows/create-app.yml`
- Modify: test-web `.github/workflows/create-app.yml`
- Modify: test-web `.app-config.yml` (type 추가)

**Step 4.1: app-starter 간소화 (§3.2 전체)**

12 입력 → 2 입력 + `read-config` job 추가 (config-yaml 전달).

**Step 4.2: test-web 간소화 + .app-config.yml 보강**

test-web 은 flat 앱이라 root `.app-config.yml` 사용. read-config job 도 root 경로:

```yaml
# test-web/create-app.yml
on:
  workflow_dispatch:
    inputs:
      subdomain: { required: false, type: string, default: "" }

permissions:
  contents: write

jobs:
  read-config:
    runs-on: ubuntu-latest
    outputs:
      config: ${{ steps.cat.outputs.config }}
    steps:
      - uses: actions/checkout@v4
      - id: cat
        run: |
          set -euo pipefail
          CONFIG_PATH=".app-config.yml"
          if [ ! -f "$CONFIG_PATH" ]; then
            echo "::error::$CONFIG_PATH not found"; exit 1
          fi
          {
            echo "config<<__EOF__"
            cat "$CONFIG_PATH"
            echo "__EOF__"
          } >> "$GITHUB_OUTPUT"

  create:
    needs: read-config
    uses: ukkiee-dev/homelab/.github/workflows/_create-app.yml@main
    with:
      app-name: ${{ github.event.repository.name }}
      subdomain: ${{ inputs.subdomain }}
      # service-name 기본 "" (flat)
      config-yaml: ${{ needs.read-config.outputs.config }}
    secrets: inherit
```

```yaml
# test-web/.app-config.yml (D2 변형: HTTP service 는 type 필드 없음)
health: /health
icon: mdi-application
description: ""
```

**Step 4.3: PR 4 (app-starter), PR 5 (test-web)**

---

### Phase 5: static 타입 템플릿 (Dockerfile + Caddyfile)

**Files:**
- Create: app-starter `services/_template-static/Dockerfile`
- Create: app-starter `services/_template-static/Caddyfile`
- Create: app-starter `services/_template-static/.app-config.yml`
- Create: app-starter `services/_template-static/package.json` (정적 빌드 도구용, 예: Vite)
- Create: app-starter `services/_template-static/index.html` (예시)

**Step 5.1: `_template-static/Dockerfile` (리뷰 C2 반영 — context=레포 루트)**

**사전 확인**: app-starter `build.yml` 의 Dockerfile build context 가 **레포 루트** 인지 **서비스 디렉토리** 인지 확인. 다음 명령으로:
```bash
gh api repos/ukkiee-dev/app-starter/contents/.github/workflows/build.yml --jq '.content' | base64 -d | grep -A3 "docker.*build\|build-and-push"
```
context=레포 루트인 경우 (composite action `build-and-push` 가 `.` 사용), 아래 Dockerfile 작성:

```dockerfile
# Build context = 레포 루트 (docker build -f services/_template-static/Dockerfile .)
# Stage 1: 빌드 (Vite 등)
FROM node:22-alpine AS builder
WORKDIR /app
COPY pnpm-workspace.yaml package.json pnpm-lock.yaml ./
COPY services/_template-static ./services/_template-static
RUN corepack enable && pnpm install --frozen-lockfile --filter _template-static...
RUN pnpm --filter _template-static build

# Stage 2: caddy 서빙
FROM caddy:2-alpine
COPY --from=builder /app/services/_template-static/dist /srv
COPY services/_template-static/Caddyfile /etc/caddy/Caddyfile
EXPOSE 3000
```

context=서비스 디렉토리인 경우 (`docker build services/_template-static/`) 는 **build-and-push composite 수정 필요** — Phase 5 범위 밖. 이 경우 별도 PR 으로 build context 통일 후 진행.

**Step 5.2: `_template-static/Caddyfile` (리뷰 m4 반영 — handle 블록으로 분리)**

```
:3000 {
    encode gzip
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        Referrer-Policy strict-origin-when-cross-origin
    }

    # /health 가 SPA fallback 에 가로채이지 않도록 명시적 handle 우선
    handle /health /healthz {
        respond 200
    }

    handle {
        root * /srv
        try_files {path} /index.html
        file_server
    }
}
```

이 구조는 Caddy v2 의 `handle` directive 우선순위로 health 응답을 SPA `try_files` 보다 명시적으로 먼저 처리한다.

**Step 5.3: `_template-static/.app-config.yml` (D2 변형: HTTP service 는 type 필드 없음)**

```yaml
# Static service (caddy + 정적 빌드)
# type 필드 없음 = HTTP service 기본 (web 과 동일 처리, Dockerfile 만 다름)

health: /health
icon: mdi-web
description: ""
```

**Note**: Phase 1 의 `_template-static/.app-config.yml` (Step 1.2) 와 중복됨. Phase 5 는 Phase 1 에서 만든 파일을 재확인하는 의미. 실제 작성은 Phase 1 에서 완료.

**Step 5.4: 루트 pnpm-workspace.yaml 확인**

이미 `services/*` 매치. 변경 불필요.

**Step 5.5: build.yml 의 Dockerfile 감지**

build.yml 의 discover step 이 이미 `find services -name Dockerfile` 이므로 static 서비스도 자동 감지.

**Step 5.6: README.md 업데이트**

"서비스 타입 추가하기" 섹션에 static 예시 추가.

**Step 5.7: PR 6 생성 (app-starter)**
- title: `feat(template): static 타입 템플릿 (caddy) 추가`

---

### Phase 6: DB reference 모드 완전 구현 (M2 — scope 확대)

**리뷰 M2**: 현재 `database/action.yml` 의 step 들이 모두 `mode == 'owner'` 조건. **reference 경로는 코드 자체가 없음** (description 만 존재). Phase 6 은 "신규 기능 구현" 수준 — 추정 시간 2h → **4h** 로 재산정.

**Files:**
- Modify: `/Users/ukyi/homelab/.github/actions/setup-app/database/action.yml` (reference 분기 신규)
- Modify: `/Users/ukyi/homelab/.github/actions/setup-app/action.yml` (reference 모드 setup-app DB step 호출, 이미 Phase 2.6 에 명시)

**Step 6.0: 현재 상태 검증** (착수 전)

```bash
grep -n "mode == 'owner'\|mode == 'reference'" .github/actions/setup-app/database/action.yml
# 모든 step 이 owner 인지, reference step 이 있는지 확인
```

**Step 6.1: `database/action.yml` reference 분기 추가**

```yaml
- name: Validate reference target exists (reference mode)
  if: steps.guard.outputs.skip != 'true' && inputs.mode == 'reference'
  shell: bash
  env:
    APP: ${{ inputs.app-name }}
    REF: ${{ inputs.ref-db }}
    HOMELAB: ${{ inputs.homelab-path }}
  run: |
    set -euo pipefail
    if [ -z "$REF" ]; then
      echo "::error::mode=reference 시 ref-db 필수 (참조할 owner 서비스 이름)"; exit 1
    fi
    REF_DIR="$HOMELAB/manifests/apps/$APP/services/$REF"
    if [ ! -d "$REF_DIR" ]; then
      echo "::error::reference 대상 서비스 디렉토리 없음: $REF_DIR"
      echo "::error::먼저 owner 서비스 ($REF) 를 생성한 후 reference 서비스를 추가하세요."
      exit 1
    fi
    # owner 의 database.yaml 또는 cluster.yaml 에서 DB·role 정보 추출
    OWNER_DB=$(yq '.spec.name' "$REF_DIR/database.yaml" 2>/dev/null || echo "")
    OWNER_ROLE=$(yq '.spec.owner' "$REF_DIR/database.yaml" 2>/dev/null || echo "")
    if [ -z "$OWNER_DB" ] || [ -z "$OWNER_ROLE" ]; then
      echo "::error::owner 서비스의 Database CR 에서 spec.name/spec.owner 추출 실패"
      exit 1
    fi
    echo "owner-db=$OWNER_DB" >> "$GITHUB_OUTPUT"
    echo "owner-role=$OWNER_ROLE" >> "$GITHUB_OUTPUT"
```

**Step 6.2: reference 서비스에 env 자동 주입**

reference 서비스의 Deployment env 에 owner 의 SealedSecret 을 참조하는 `DATABASE_URL` env 추가:

```yaml
- name: Inject DATABASE_URL env into reference service
  if: steps.guard.outputs.skip != 'true' && inputs.mode == 'reference'
  shell: bash
  env:
    APP: ${{ inputs.app-name }}
    SERVICE: ${{ inputs.service-name }}
    REF: ${{ inputs.ref-db }}
    OWNER_DB: ${{ steps.validate-ref.outputs.owner-db }}
    OWNER_ROLE: ${{ steps.validate-ref.outputs.owner-role }}
    HOMELAB: ${{ inputs.homelab-path }}
  run: |
    set -euo pipefail
    DEPLOYMENT="$HOMELAB/manifests/apps/$APP/services/$SERVICE/deployment.yaml"

    # owner 의 role-secret 이름 (예: $REF-$OWNER_ROLE)
    SECRET_NAME="${REF}-${OWNER_ROLE}"

    # Deployment env 에 DATABASE_URL secret reference 추가 (idempotent)
    SECRET_NAME="$SECRET_NAME" OWNER_DB="$OWNER_DB" CLUSTER_HOST="${APP}-pg-rw.${APP}.svc" \
    yq eval -i '
      .spec.template.spec.containers[0].env = (
        (.spec.template.spec.containers[0].env // []) + [
          {
            "name": "DATABASE_URL",
            "valueFrom": {
              "secretKeyRef": {
                "name": env(SECRET_NAME),
                "key": "uri"
              }
            }
          }
        ] | unique_by(.name)
      )
    ' "$DEPLOYMENT"
    echo "OK reference DATABASE_URL env 주입 완료 ($SECRET_NAME)"
```

**Step 6.3: setup-app/action.yml 의 reference step 활성화**

Phase 2.6 에서 placeholder 추가한 reference step 을 실제 동작 가능하도록 inputs 완성.

**Step 6.4: PR 7 생성 (homelab)**
- title: `feat(setup-app/db): reference 모드 신규 구현 (M2)`
- 추정: 4 시간 (검증 + env 주입 로직 + 테스트)

---

### Phase 7: 마이그레이션 + immutability guard + teardown 정합 + 문서

**Files:**
- Modify: `/Users/ukyi/homelab/.github/workflows/_sync-app-config.yml` (database immutability guard, M1)
- Modify: `/Users/ukyi/homelab/.github/workflows/_teardown.yml` (config-yaml 기반 DB 정리 확인)
- Create (사용자): pokopia-wiki `services/api/.app-config.yml` (없으면)
- Modify: homelab `docs/runbooks/postgresql/cnpg-new-project.md` (새 .app-config.yml 방식 반영)
- Modify: homelab `docs/disaster-recovery.md` (app-starter 언급 부분 갱신)
- Modify: app-starter `README.md` (사용 흐름 + 타입별 예시 + DB 예시)

**참고**: test-web `.app-config.yml` 갱신은 Phase 4.2 에서 이미 처리 (caller 업데이트와 묶음).

**Step 7.1: `_sync-app-config.yml` database immutability guard (M1)**

`.app-config.yml` 변경 push 시 `database` 블록이 변경되었는지 감지하고, **변경됐다면 reflexion 막고 `::error::` 출력**:

```yaml
# _sync-app-config.yml 에 추가
- name: Detect database block drift (immutability guard)
  shell: bash
  env:
    APP: ${{ inputs.app-name }}
    SERVICE: ${{ inputs.service }}
  run: |
    set -euo pipefail
    if [ -n "$SERVICE" ]; then
      CONFIG_PATH="services/$SERVICE/.app-config.yml"
      MANIFEST_DIR="manifests/apps/$APP/services/$SERVICE"
    else
      CONFIG_PATH=".app-config.yml"
      MANIFEST_DIR="manifests/apps/$APP"
    fi

    DB_NAME=$(yq '.database.name // ""' "_app/$CONFIG_PATH")
    DB_REF=$(yq '.database.ref // ""' "_app/$CONFIG_PATH")

    # 현재 매니페스트의 DB 설정 조회
    CURRENT_DB=""
    if [ -f "_homelab/manifests/apps/$APP/common/database-shared.yaml" ]; then
      CURRENT_DB=$(yq '.spec.name // ""' "_homelab/manifests/apps/$APP/common/database-shared.yaml")
    fi

    if [ -n "$DB_NAME" ] && [ -n "$CURRENT_DB" ] && [ "$DB_NAME" != "$CURRENT_DB" ]; then
      echo "::error::database.name 변경 감지: '$CURRENT_DB' → '$DB_NAME'"
      echo "::error::DB 이름 변경은 자동 마이그레이션 불가. 다음 절차 사용:"
      echo "::error::  1. (옵션) 기존 DB pg_dump → 새 DB 복원"
      echo "::error::  2. teardown 후 새 .app-config.yml 로 create-app 재실행"
      echo "::error::  3. Runbook docs/runbooks/postgresql/cnpg-new-project.md 참조"
      exit 1
    fi
    echo "OK database 블록 drift 없음"
```

**Step 7.2: `_teardown.yml` config-yaml 기반 정리 검증**

teardown 시 `.app-config.yml` 의 `database.name` 이 있으면 R2 backup prefix 도 정리할지 확인 (현재는 retentionPolicy 가 처리). 사용자에게 명시적 안내:

```bash
# _teardown.yml 의 manifest 제거 step 뒤
- name: Notify R2 backup retention
  if: steps.detect-mode.outputs.had-database == 'true'
  run: |
    echo "::notice::DB 가 있던 앱 ($APP_NAME) 의 R2 backup prefix 는 ObjectStore retentionPolicy (7d) 로 자동 만료"
    echo "::notice::즉시 삭제 필요 시: aws s3 rm s3://homelab-db-backups/${APP_NAME}-pg/ --recursive"
```

memory `project_teardown_silent_failure.md` 의 silent failure 패턴 참고하여 curl/awscli timeout 회피.

**Step 7.3: pokopia-wiki 마이그레이션 (사용자 수동)**

pokopia-wiki 는 외부 레포라 plan 직접 수정 불가. 사용자 안내:
```yaml
# pokopia-wiki/services/api/.app-config.yml (D2 변형: HTTP service 는 type 필드 없음)
health: /health
icon: mdi-book-open-variant
description: "pokopia wiki engine"
database:
  name: wiki
  storage: 10Gi
```

**Step 7.4: Runbook 갱신**

`cnpg-new-project.md`:
- 시나리오 A/B/C 의 dispatch input 안내를 `.app-config.yml` 작성 기반으로 교체
- DB 모드 결정 (name vs ref) 섹션 추가
- immutability guard 가 작동하는 시나리오 (DB 이름 변경 시도) 트러블슈팅 추가

`disaster-recovery.md`:
- §1 Applications 표의 "CNPG Clusters" 행 설명에 ".app-config.yml.database 로 선언" 추가

**Step 7.5: app-starter README 완성**

- 전체 사용 흐름:
  1. 템플릿에서 새 레포 생성
  2. `services/<svc>/.app-config.yml` 작성 (type, health, icon, description, [database])
  3. `create-app.yml` workflow_dispatch (service-name, subdomain)
  4. 코드 push → build.yml 이 GHCR 에 이미지 push → ArgoCD sync
- 각 타입별 예시 (web/static/worker)
- DB 추가 예시 (owner + reference)
- 트러블슈팅 (config-yaml 미존재, DB drift 등)

**Step 7.6: PR 6 (app-starter README), PR 7 (homelab docs + immutability guard + teardown), 사용자 수동 PR (pokopia-wiki)**

---

## 5. 마이그레이션 리스크 & 완화 (리뷰 반영)

| 리스크 | 영향 | 완화 |
|--------|------|------|
| **C3** Phase 3 머지 → caller 업데이트 전 호환성 갭 | 모든 create-app 호출 startup_failure | **Phase 3 deprecation-first** (입력 유지) + **Phase 2 hybrid fallback** + **Phase 3b 별도 cleanup** (모든 caller 업데이트 후) |
| **C1** 앱 레포 토큰 범위 부족 | Phase 2 의 fetch 방식 실패 | **D4 옵션 A** (caller 측 파싱, config-yaml 전달). 토큰 변경 불필요 |
| **C2** Docker COPY `../../` 위반 | static 빌드 실패 | context=레포 루트 + `services/_template-static/` 명시 경로 (Phase 5.1) |
| **C4** project=default vs apps 불일치 | AppProject destinations 자동 등록과 따로 놂 | Phase 2.7 에서 `project: apps` 로 통일. AppProject destinations 자동 등록 step 이미 존재 → 정합 |
| **M1** database 변경 silent ignore | 사용자 혼란 (DB 이름 바꿔도 반영 안 됨) | Phase 7.1 immutability guard step → `::error::` 출력 + 명시적 마이그레이션 가이드 |
| **M2** reference 모드 미구현 | reference 사용 시 즉시 실패 | Phase 6 scope 확대 (4h), composite 신규 step 2 개 |
| **M5** Phase 2 → 4 사이 caller 무효화 | inputs.app-type=worker 가 silently 무시 | hybrid fallback (config-yaml 비어있으면 deprecated inputs 사용) — Phase 2.3 |
| `.app-config.yml` 없는 기존 앱 | default (web) 적용 | setup-app 이 기본값 처리 — 기존 동작 호환 |
| pokopia-wiki 현재 동작 | `.app-config.yml` 없음, 매니페스트 직접 작성 상태 | 영향 없음 (이미 배포됨), Phase 7.3 `.app-config.yml` 추가 권장 |
| static 타입 Caddyfile 검증 | 첫 배포 시 실패 가능 | Phase 5 이후 실제 static 앱 테스트 필요 (m4 handle 블록 적용) |
| workflow_call permissions 회귀 | startup_failure (2026-04-21 대란 재발) | 모든 reusable 에 permissions 블록 없음 유지 — memory `feedback_workflow_call_permissions.md` 준수 |
| Teardown silent failure (memory) | 실패가 성공처럼 보임 | Phase 7.2 에서 curl/awscli timeout 처리 — memory `project_teardown_silent_failure.md` 패턴 회피 |

---

## 6. 검증 계획

### 6.1 Phase 별 수락 기준 (m2 pipe escape 반영)

| Phase | 검증 명령 | 기대 결과 |
|-------|-----------|-----------|
| 1 | `yq '.' services/_template-*/.app-config.yml` | 3개 파일 모두 유효 YAML |
| 2 | setup-app dry-run + config-yaml 전달 (pokopia-wiki 가상 .app-config.yml) | type=web, db-mode=owner, db-name=wiki 출력. project=apps 적용 확인 |
| 2 | hybrid fallback 검증 — config-yaml="" 로 호출 + inputs.app-type=worker | type=worker 로 결정 (deprecated input 사용) |
| 3 | `yq '.on.workflow_call.inputs` <code>&#124;</code> `keys' _create-app.yml` | 14개 키 (기존 13 + config-yaml). deprecated 모두 `required: false` |
| 3b | (Phase 7 후) 동일 명령 | 4개 키 (app-name, service-name, subdomain, config-yaml) |
| 4 | 새 test 레포 + create-app dispatch | <30s 내 SUCCESS, homelab PR 생성 |
| 5 | static 서비스 빌드 + 배포 | caddy 포트 3000 응답, `/health` 200, `/healthz` 200 |
| 6 | owner + reference 서비스 순차 생성 | owner DB 생성, reference 서비스 env 에 DATABASE_URL 주입 (`kubectl get deploy -n <app> <ref-svc> -o jsonpath='{.spec.template.spec.containers[0].env}'`) |
| 6 | reference 모드에서 owner 미존재 호출 | `::error::reference 대상 서비스 디렉토리 없음` + workflow 실패 |
| 7 | test-web `.app-config.yml` 변경 + push | `_sync-app-config.yml` 이 IngressRoute annotation 갱신 |
| 7 | test-web `.app-config.yml` 의 `database.name` 변경 + push | `::error::database.name 변경 감지` + workflow 실패 (immutability guard) |

### 6.2 End-to-end 검증 시나리오

새 테스트 레포 `ukkiee-dev/test-phase8` (일회성) 생성 후:

1. app-starter 템플릿에서 생성
2. `services/web/.app-config.yml` 작성 (HTTP service — type 필드 없음, `database.name: testdb`)
3. 초기 push → build.yml 이 services/web 빌드 (Phase 2 이전엔 실패, 이후엔 성공)
4. `create-app.yml` dispatch (service-name=web, subdomain=)
5. 검증:
   - [ ] homelab `manifests/apps/test-phase8/services/web/` 생성
   - [ ] `manifests/apps/test-phase8/common/cluster.yaml` (CNPG Cluster) 생성
   - [ ] ArgoCD Application project=apps, ignoreDifferences 자동 포함
   - [ ] AppProject destinations 자동 등록 (apps + infra)
   - [ ] Pod ImagePullBackOff (이미지 아직 없음) 예상됨
6. 앱 레포에 실제 코드 push → build.yml 이 GHCR 에 이미지 푸시 + `_update-image.yml` 호출
7. ArgoCD sync → Pod Running + Ready
8. teardown: `gh workflow run teardown.yml -f app-name=test-phase8`
9. PR #18 의 역방향 자동 제거 검증

### 6.3 회귀 테스트

- test-web 은 flat 앱이므로 `.app-config.yml` 루트 경로 읽기 정상 동작
- pokopia-wiki 는 기존 매니페스트 유지, `.app-config.yml` 추가만으로 health/icon 갱신

---

## 7. Out of Scope (후속)

- **Postgres major upgrade**: 이 plan 범위 밖, `cnpg-upgrade.md` 별도 계획
- **worker 재설계**: D2 옵션 A 유지 (기본 셋팅만)
- **.app-config.yml JSON Schema 검증**: pre-commit hook 또는 actionlint custom rule — YAGNI 단계
- **role-name 커스터마이즈**: 기본값 = service-name, override 는 추후 확장
- **database-pg-image-tag override**: `.app-config.yml` 에 추가하지 않음 — Renovate + 내부 default 로 충분
- **multi-DB per service**: 한 서비스가 여러 DB 참조 — 현재 사용 사례 없음
- **기존 자동 생성 Application 의 project=default → apps 마이그레이션**: §C4 영향 평가에서 "신규 앱부터" 적용. 기존 앱은 수동 PR 또는 별도 Phase 에서 처리.
- **DB 이름 변경 자동 마이그레이션**: §M1 immutability guard 가 차단. pg_dump → restore 절차는 Runbook 별도 작성.

---

## 8. PR 순서 & 머지 전략 (리뷰 C3 반영 — deprecation-first)

| 순번 | 레포 | PR 제목 | 의존 | 비고 |
|------|------|---------|------|------|
| PR 1 | app-starter | `docs: .app-config.yml 스키마 확장 (type + database)` | 없음 | 템플릿 + README |
| PR 2 | homelab | `feat(setup-app): config-yaml 파싱 + hybrid fallback + project=apps + yq 순서 앞당김` | 없음 | C1·C4·M4·M5 일괄 |
| PR 3 | homelab | `feat(workflow): _create-app.yml 에 config-yaml 입력 추가 (deprecation-first)` | PR 2 | C3 — deprecated 유지 |
| PR 4 | app-starter | `refactor: create-app.yml 2-input + read-config job` | PR 3 | caller 업데이트 |
| PR 5 | test-web | `refactor: create-app.yml + .app-config.yml type 추가` | PR 3 | caller 업데이트 |
| PR 6 | app-starter | `feat(template): static 타입 (caddy) 템플릿` | PR 1 | 독립 |
| PR 7 | homelab | `feat(setup-app/db): reference 모드 신규 구현` | PR 2 | M2 — 4h scope |
| PR 8 | homelab | `feat(workflow): _sync-app-config database immutability guard + teardown 정합 + 문서` | PR 2, 4, 5 | M1 + Phase 7 통합 |
| 수동 | pokopia-wiki | `feat: services/<svc>/.app-config.yml 도입` | PR 2 | 사용자 작성 |
| **PR 9** | homelab | `refactor: _create-app.yml + setup-app deprecated inputs 제거 (Phase 3b)` | PR 4·5·수동 (모든 caller) | C3 cleanup |

**핵심 머지 전략**:
1. **PR 2 머지 즉시** caller 업데이트 없이도 hybrid fallback 으로 기존 동작 유지 → **호환성 갭 0**.
2. **PR 3 머지 즉시** 모든 기존 caller 가 그대로 동작 (deprecated 모두 `required: false`).
3. PR 4/5/수동 의 caller 업데이트는 **개별 페이스로** 진행.
4. 모든 caller 가 `config-yaml` 사용으로 전환됐다고 확인된 후 **PR 9 (cleanup)** 머지.

리뷰 C3 우려 (30 분 머지 창 보장 불가) 가 deprecation-first 로 완전 해소.

---

## 9. 성공 기준 (리뷰 반영)

- [ ] app-starter `create-app.yml` 입력 2 개 (service-name, subdomain) 만 남음
- [ ] `.app-config.yml` 만으로 type·health·icon·description·database 모두 선언 가능
- [ ] test-web + pokopia-wiki 모두 새 스키마로 동작
- [ ] static 타입 서비스가 caddy 로 배포 + `/health` + `/healthz` 응답
- [ ] owner/reference 모드가 `.app-config.yml` 의 `name`/`ref` 필드로 자동 판단
- [ ] reference 모드에서 owner 미존재 시 명확한 `::error::` 출력
- [ ] reference 서비스 Deployment 에 DATABASE_URL env 자동 주입
- [ ] **C4**: 신규 ArgoCD Application 이 `project: apps` 로 생성, AppProject destinations 자동 등록과 정합
- [ ] **M1**: `.app-config.yml.database` 변경 시 `_sync-app-config.yml` 이 `::error::` + 마이그레이션 가이드 출력
- [ ] **C3**: Phase 3 머지 후 Phase 3b 전 까지 모든 기존 caller 정상 동작 (hybrid fallback)
- [ ] 기존 Runbook + DR 문서 갱신
- [ ] end-to-end 테스트 (test-phase8) SUCCESS + teardown 자동 정리 + AppProject destinations 자동 제거

---

## 10. 타임라인 (추정 — 리뷰 반영 갱신)

| 구간 | 소요 | 비고 |
|------|------|------|
| Phase 1 | 1 시간 | 템플릿 + README |
| Phase 2 | 4 시간 | setup-app 대폭 수정 (+ hybrid fallback + project=apps + yq 순서) |
| Phase 3 | 1 시간 | config-yaml input 추가 + deprecation 정리 |
| Phase 4 | 1 시간 | caller 수정 x 2 (read-config job 추가) |
| Phase 5 | 2 시간 | Dockerfile (context=루트) + Caddyfile (handle 블록) + 예시 빌드 |
| Phase 6 | 4 시간 | reference 모드 신규 구현 (M2 — owner+ref env 주입 로직) |
| Phase 7 | 3 시간 | immutability guard + teardown + 문서 + 마이그레이션 |
| Phase 3b | 30 분 | deprecated cleanup (모든 caller 검증 후) |
| **합계** | **~16.5 시간** | 분산 진행 권장 (Phase 2 후 caller 업데이트는 며칠 텀 가능) |
