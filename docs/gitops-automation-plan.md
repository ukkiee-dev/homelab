# GitOps 자동화 구현 계획 v6

## 버전별 수정 이력

### v3 → v4

| # | 문제 | 심각도 | 수정 |
|---|---|---|---|
| 2 | Cloudflared가 ConfigMap이 아닌 TUNNEL_TOKEN 방식 | Critical | `cloudflare_tunnel_config` Terraform 리소스로 ��체 |
| 9 | git retry 로직 버그 | Critical | commit 분리, push만 retry |
| 7 | terraform 전에 git push | High | 순서 변경: terraform → git push |
| 5 | Deployment에 probe/securityContext/labels 누락 | High | type별 분기 추가 |
| 6 | type 입력 미사용 | High | type별 분기 처리 추가 |
| 4 | 앱별 독립 NS vs 기존 공유 NS 불일치 | Medium | 독립 NS 유지, 주의사항 명시 |
| 8 | sed 이미지 태그 교체 취약 | Medium | yq로 교체 |
| 10 | 롤백 비대칭 | Medium | `teardown.yml` 추가 |
| 11-15 | 기타 | Low | force_path_style, provider version, 알림, retry 등 수정 |

### v4 → v5 (2차 리뷰 반영)

| # | 문제 | 심각도 | 수정 |
|---|---|---|---|
| 1 | GitHub Org 이름 `ukkiee` → 실제 `ukkiee-dev` | Critical | 전체 치환 |
| 2-3 | GHCR imagePullSecrets chicken-and-egg | Critical | K3s registries.yaml로 전환 |
| 4 | SPA + `runAsNonRoot` + port 80 충돌 | High | SPA 기본 포트 8080, nginx-unprivileged |
| 5 | `terraform import` 누락 | High | Phase 1-5에 import 절차 추가 |
| 6 | Teardown 순서 문제 | High | terraform → git push 순서 |
| 7 | `git add .`가 terraform 아티팩트 포함 | High | 명시적 경로 지정 |
| 8-11 | port 검증, NS 정리, Heredoc 등 | Medium~Low | 각각 수정 |

### v5 → v6 (3차 리뷰 — 실제 레포 상태 교차 검증)

| # | 문제 | 심각도 | 수정 |
|---|---|---|---|
| 1 | `apps.json` 서브도메인 불일치: immich→실제 `photos`, adguard→`dns`인데 실제 `adguard` | Critical | apps.json 수정 + 대시보드 확인 경고 강화 |
| 2 | `apps.json` 불완전: tunnel 라우팅 서비스 누락 시 기존 서비스 장애 | Critical | 대시보드 확인 필수 절차 명시, 예시 확장 |
| 3 | IngressRoute `websecure`만 → tunnel HTTP(port 80) 트래픽 미수신 | Critical | `web` + `websecure` 양쪽 entryPoint |
| 4 | ArgoCD Application `repoURL`에 `.git` 접미사 누락 (기존 앱과 불일치) | High | `.git` 추가 |
| 5 | IngressRoute에 middleware 완전 누락 (security-headers 등) | High | cross-namespace middleware 참조 추가 |
| 6 | `tunnel.tf` service URL이 현재 대시보드 설정과 다를 수 있음 | High | 검증 절차 추가 |
| 7 | `concurrency: homelab-terraform`이 레포 단위 격리 → 동시 setup 충돌 | Medium | 주의사항 명시 |
| 8 | Teardown에 실패 알림 없음 | Medium | `if: failure()` 추가 |
| 9 | Teardown `subdomain` 입력이 알림에만 사용 (오입력 가능) | Low | apps.json에서 자동 추출 |
| 10 | IngressRoute에 `tls: certResolver` 불필요 — 기존 앱과 패턴 불일치 | Medium | `tls` 섹션 제거, 와일드카드 인증서 사용 |
| 11 | push retry 3회 실패 시 silent success (exit 1 없음) | Medium | `$PUSHED` 플래그 + `exit 1` 추가 |
| 12 | push retry 중 rebase 실패 상태 미정리 | Low | `git rebase --abort` 방어 코드 추가 |
| 13 | apps.json에 Tailscale A 레코드 앱 포함 → A→CNAME 타입 충돌 + 내부 서비스 공개 노출 | **Critical** | tunnel 경유 앱(photos)만 포함, Tailscale 앱 제거 |

---

## 목표

새 앱 레포 생성 후 `.app-config.yml` 수정 + `git push` 만으로
빌드 → 배포 → DNS + Tunnel 라우팅 등록까지 자동화

```
template 기반 레포 생성
  └─ .app-config.yml 수정 & git push
       └─ ci.yml (순차적, 4개 job)
            ├─ check:            매니페스트 존재 여부 확인
            ├─ setup:            [최초 1회] terraform → homelab git push
            │                    DNS + Tunnel ingress 등록 → 매니페스트 생성
            ├─ deploy:           [매 push] Docker 빌드 & GHCR 푸시
            └─ update-manifest:  [매 push] 이미지 태그 갱신 → ArgoCD 배포
```

> **순서 보장**: terraform apply (DNS + Tunnel 완료) → git push (ArgoCD sync 시작)
> DNS가 없는 상태에서 앱이 배포되는 상황 방지

---

## 전체 구조

```
github.com/ukkiee-dev/
├── homelab/
│   ├── .github/
│   │   ├── actions/
│   │   │   └── setup-app/
│   │   │       └── action.yml      # composite action
│   │   └── workflows/
│   │       ├── _update-image.yml   # reusable: 이미지 태그 갱신
│   │       └── teardown.yml        # 앱 제거 자동화 (신규)
│   └── terraform/
│       ├── backend.tf
│       ├── provider.tf
│       ├── variables.tf
│       ├── dns.tf                  # DNS CNAME 레코드
│       ├── tunnel.tf               # cloudflare_tunnel_config (신규)
│       └── apps.json               # 앱 목록 (DNS + tunnel ingress 공통)
│
├── template-static/            # static 타입 (SPA, SSG)
├── template-web/               # web 타입 (HTTP 서버, 언어 무관)
└── my-blog/                    # template-web 기반 실제 앱
```

---

## Phase 1 — 사전 준비

### 1-1. GitHub App 생성

```
GitHub → Settings → Developer settings → GitHub Apps → New GitHub App

설정:
  GitHub App name: ukkiee-deploy-bot
  Homepage URL:    https://github.com/ukkiee-dev
  Webhooks:        □ Active (반드시 체크 해제)

  Repository permissions:
    Contents: Read & Write
    Metadata: Read (자동 선택)

  Where can this be installed: Only on this account
```

생성 후:
```
1. App ID 메모 (페이지 상단 "App ID: XXXXXX")
2. Generate a private key → .pem 다운로드
3. Install App → ukkiee-dev Org
   → Only select repositories → homelab → Install
```

---

### 1-2. Org Secrets 등록

```
github.com/orgs/ukkiee-dev → Settings → Secrets and variables → Actions
→ New organization secret → Repository access: All repositories
```

| Secret 이름 | 값 | 용도 |
|---|---|---|
| `HOMELAB_APP_ID` | GitHub App ID | GitHub App 인증 |
| `HOMELAB_APP_PRIVATE_KEY` | .pem 전체 내용 | GitHub App 인증 |
| `TF_CLOUDFLARE_TOKEN` | Cloudflare API Token | DNS + Tunnel 관리 |
| `TF_ZONE_ID` | ukkiee.dev Zone ID | DNS 대상 Zone |
| `TF_TUNNEL_ID` | cloudflared Tunnel ID | CNAME target + tunnel config |
| `TF_ACCOUNT_ID` | Cloudflare Account ID | R2 backend + tunnel config |
| `R2_ACCESS_KEY_ID` | R2 API Token Access Key | Terraform state backend |
| `R2_SECRET_ACCESS_KEY` | R2 API Token Secret Key | Terraform state backend |
| `TELEGRAM_BOT_TOKEN` | Telegram Bot Token | 실패 알림 |
| `TELEGRAM_CHAT_ID` | Telegram Chat ID | 실패 알림 수신 |

Cloudflare API Token 권한:
```
Cloudflare 대시보드 → My Profile → API Tokens → Create Token → Custom token

필요 권한:
  Zone: DNS → Edit        (ukkiee.dev zone)
  Account: Cloudflare Tunnel → Edit   ← tunnel_config 리소스에 필요 (v3 누락)
```

> **검증**: `cloudflare_tunnel_config` 리소스는 Account-level 권한 필요.
> Zone:DNS 권한만 있으면 tunnel config 적용 시 403 에러 발생.

---

### 1-3. GHCR 인증 — K3s registries.yaml (노드 레벨)

네임스페이스별 `imagePullSecrets` 대신 **K3s 노드 레벨에서 GHCR 인증**을 설정.
PreSync Job이나 SealedSecret 없이 모든 네임스페이스에서 GHCR pull 가능.

```bash
# 1. GitHub PAT 발급 (read:packages 권한)
#    GitHub → Settings → Developer settings → Personal access tokens
#    → Fine-grained tokens → Permissions: Packages → Read

# 2. K3s registries.yaml 생성 (OrbStack K3s — kubectl debug 사용)
#    OrbStack K3s는 systemd 없이 직접 프로세스로 실행.
#    /etc/rancher/k3s/ 디렉토리 존재 확인됨, registries.yaml은 신규 생성.
GHCR_PAT="<여기에_PAT_입력>"

kubectl debug node/orbstack -it --image=alpine -- sh -c "
cat > /host/etc/rancher/k3s/registries.yaml << INNER_EOF
mirrors:
  ghcr.io:
    endpoint:
      - \"https://ghcr.io\"
configs:
  ghcr.io:
    auth:
      username: ukkiee-dev
      password: \"$GHCR_PAT\"
INNER_EOF
cat /host/etc/rancher/k3s/registries.yaml
"

# 3. K3s 재시작 (OrbStack — systemctl 없음)
#    OrbStack 메뉴바 → 우클릭 → Kubernetes → Restart
#    또는 OrbStack 설정 → Kubernetes → 토글 Off → On

# 4. 검증 (재시작 후)
kubectl run --rm -it ghcr-test --image=ghcr.io/ukkiee-dev/api-server:latest --restart=Never -- echo "pull success"
# 또는 기존 deployment를 rollout restart 후 ImagePullBackOff 없는지 확인
```

> **장점**: Deployment에 `imagePullSecrets` 불필요, 네임스페이스 무관하게 동작.
> **주의**: PAT 만료 시 노드에서 재설정 필요. PAT 유효기간을 길게 설정(1년) 권장.

---

### 1-4. Cloudflare R2 — Terraform State 버킷

```
Cloudflare 대시보드 → R2 → Create bucket
  Name: ukkiee-terraform-state
  Location: Automatic
```

R2 API Token:
```
R2 → Manage R2 API Tokens → Create API Token
  Permissions: Object Read & Write
  Specify bucket: ukkiee-terraform-state
→ Access Key ID, Secret Access Key → Org Secrets에 등록
```

---

### 1-5. homelab — Terraform 초기 설정

**`backend.tf`**:
```hcl
terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.48"   # 범위 축소로 breaking change 방지
    }
  }

  backend "s3" {
    bucket = "ukkiee-terraform-state"
    key    = "homelab/terraform.tfstate"
    region = "auto"

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    use_path_style              = true   # force_path_style deprecated → use_path_style
    # endpoint는 terraform init -backend-config으로 주입
  }
}
```

**`provider.tf`**:
```hcl
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
```

**`variables.tf`**:
```hcl
variable "cloudflare_api_token" {
  description = "Cloudflare API Token (Zone:DNS Edit + Tunnel Edit)"
  sensitive   = true
}

variable "zone_id" {
  description = "ukkiee.dev Cloudflare Zone ID"
  sensitive   = true
}

variable "tunnel_id" {
  description = "cloudflared Tunnel ID"
}

variable "account_id" {
  description = "Cloudflare Account ID"
}
```

**`apps.json`** — **Tunnel 경유 앱만 포함** (Tailscale A 레코드 앱은 포함하지 않음):
```json
{
  "immich": { "subdomain": "photos" }
}
```

> **현재 DNS 구조** (Cloudflare 대시보드 확인 완료):
> | 서브도메인 | DNS 타입 | 접근 방식 | terraform 관리 |
> |---|---|---|---|
> | `photos` | Tunnel CNAME (Proxied) | Cloudflare Tunnel (공개) | **apps.json으로 관리** |
> | `grafana`, `adguard`, `home`, `api`, `argo`, `status`, `traefik` | A 레코드 → `100.112.20.3` (DNS only) | Tailscale 직접 접근 | **terraform 미관리** |
>
> Tailscale A 레코드 앱을 apps.json에 포함하면:
> - A 레코드 → CNAME 레코드로 **타입 변경** → 기존 Tailscale 접근 깨짐
> - tunnel ingress에 추가 → **내부 전용 서비스가 공개 인터넷에 노출**
>
> 새로 자동 배포되는 앱은 tunnel 경유(공개)로 등록됨.

**`dns.tf`**:
```hcl
locals {
  apps = jsondecode(file("${path.module}/apps.json"))
}

resource "cloudflare_record" "apps" {
  for_each = local.apps

  zone_id = var.zone_id
  name    = each.value.subdomain
  value   = "${var.tunnel_id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
}
```

**`tunnel.tf`** (신규 — cloudflared ConfigMap 대체):
```hcl
resource "cloudflare_tunnel_config" "homelab" {
  account_id = var.account_id
  tunnel_id  = var.tunnel_id

  config {
    # apps.json 기반으로 ingress rule 동적 생성
    dynamic "ingress_rule" {
      for_each = local.apps
      content {
        hostname = "${ingress_rule.value.subdomain}.ukkiee.dev"
        service  = "http://traefik:80"   # 현재 tunnel 설정과 동일 (cloudflared 로그 확인)
      }
    }

    # catch-all은 반드시 마지막
    ingress_rule {
      service = "http_status:404"
    }
  }
}
```

> **검증**: `cloudflare_tunnel_config`는 전체 config를 덮어씀 (append 아님).
> apps.json에서 앱 제거 후 apply하면 해당 ingress rule이 자동 삭제됨 → 롤백 자동화 가능.

> **검증 — service URL**: `http://traefik:80`은 cloudflared 로그(version 20)에서 확인한 실제 값.
> cloudflared pod(networking NS)에서 traefik service로 라우팅됨.

**초기 실행**:
```bash
cd terraform

terraform init \
  -backend-config="endpoint=https://${TF_ACCOUNT_ID}.r2.cloudflarestorage.com" \
  -backend-config="access_key=${R2_ACCESS_KEY_ID}" \
  -backend-config="secret_key=${R2_SECRET_ACCESS_KEY}"

# ⚠️ 기존 리소스 import 필수 (이미 Cloudflare에 존재하는 레코드)
# import 없이 apply하면 "Record already exists" 에러 발생

# 현재 tunnel 경유 앱은 photos(immich) 1개뿐
# DNS CNAME 레코드 import
terraform import 'cloudflare_record.apps["immich"]' ${TF_ZONE_ID}/<record-id>   # photos.ukkiee.dev

# Tunnel config import
terraform import 'cloudflare_tunnel_config.homelab' ${TF_ACCOUNT_ID}/${TF_TUNNEL_ID}

# record-id 조회:
# curl -s -H "Authorization: Bearer $TF_CLOUDFLARE_TOKEN" \
#   "https://api.cloudflare.com/client/v4/zones/${TF_ZONE_ID}/dns_records?name=photos.ukkiee.dev" \
#   | jq '.result[] | {name, id, type}'

terraform plan   # 변경사항 없음(No changes) 확인 후
terraform apply
```

> **검증**: `terraform plan`에서 "No changes" 확인.
> destroy + create가 표시되면 import가 누락되었거나 값이 불일치.
>
> **주의 — Tailscale A 레코드는 terraform으로 관리하지 않음**:
> grafana, adguard, home, api, argo, status, traefik은 Tailscale IP(`100.112.20.3`)를
> 가리키는 A 레코드이며, terraform 범위 밖.
> 이 레코드를 실수로 apps.json에 추가하면 A→CNAME 타입 변경 + 공개 노출 사고 발생.

---

## Phase 2 — homelab 설정

### 2-1. composite action: `setup-app`

**`homelab/.github/actions/setup-app/action.yml`**:

```yaml
name: Setup App in Homelab
description: Terraform(DNS+Tunnel) → 매니페스트 생성 → git push 순서 보장

inputs:
  app-name:             { required: true }
  type:                 { required: true }   # static | web | worker
  port:                 { required: true }
  subdomain:            { required: true }
  health:               { required: false }  # 헬스체크 경로 (static: /, web: /health)
  app-token:            { required: true }
  tf-cloudflare-token:  { required: true }
  tf-zone-id:           { required: true }
  tf-tunnel-id:         { required: true }
  tf-account-id:        { required: true }
  r2-access-key-id:     { required: true }
  r2-secret-access-key: { required: true }

runs:
  using: composite
  steps:
    - name: Checkout homelab
      uses: actions/checkout@v4
      with:
        repository: ukkiee-dev/homelab
        token: ${{ inputs.app-token }}
        path: _homelab

    # ── Step 1: apps.json 업데이트 (terraform 전에) ──────────────
    - name: Update apps.json
      shell: bash
      run: |
        set -euo pipefail
        APP="${{ inputs.app-name }}"
        SUBDOMAIN="${{ inputs.subdomain }}"
        APPS_JSON="_homelab/terraform/apps.json"

        EXISTS=$(jq --arg name "$APP" 'has($name)' "$APPS_JSON")
        if [ "$EXISTS" = "true" ]; then
          echo "⏭️  apps.json: $APP 이미 존재, 스킵"
        else
          jq --arg name "$APP" --arg sub "$SUBDOMAIN" \
            '. + {($name): {subdomain: $sub}}' \
            "$APPS_JSON" > /tmp/apps.json
          jq empty /tmp/apps.json  # JSON 유효성 검증
          mv /tmp/apps.json "$APPS_JSON"
          echo "✅ apps.json: $APP ($SUBDOMAIN) 추가됨"
        fi

    # ── Step 2: Terraform (DNS + Tunnel ingress) ─────────────────
    # git push 전에 실행 → DNS 없는 상태로 앱 배포되는 상황 방지
    - name: Setup Terraform
      uses: hashicorp/setup-terraform@v3
      with:
        terraform_version: "1.7.0"

    - name: Terraform Init
      shell: bash
      working-directory: _homelab/terraform
      run: |
        terraform init \
          -backend-config="endpoint=https://${{ inputs.tf-account-id }}.r2.cloudflarestorage.com" \
          -backend-config="access_key=${{ inputs.r2-access-key-id }}" \
          -backend-config="secret_key=${{ inputs.r2-secret-access-key }}"

    - name: Terraform Plan
      shell: bash
      working-directory: _homelab/terraform
      run: terraform plan -out=tfplan
      env:
        TF_VAR_cloudflare_api_token: ${{ inputs.tf-cloudflare-token }}
        TF_VAR_zone_id:              ${{ inputs.tf-zone-id }}
        TF_VAR_tunnel_id:            ${{ inputs.tf-tunnel-id }}
        TF_VAR_account_id:           ${{ inputs.tf-account-id }}

    - name: Terraform Apply
      shell: bash
      working-directory: _homelab/terraform
      run: terraform apply tfplan
      env:
        TF_VAR_cloudflare_api_token: ${{ inputs.tf-cloudflare-token }}
        TF_VAR_zone_id:              ${{ inputs.tf-zone-id }}
        TF_VAR_tunnel_id:            ${{ inputs.tf-tunnel-id }}
        TF_VAR_account_id:           ${{ inputs.tf-account-id }}

    # ── Step 3: k8s 매니페스트 생성 ──────────────────────────────
    - name: Create manifests
      shell: bash
      run: |
        set -euo pipefail
        APP="${{ inputs.app-name }}"
        TYPE="${{ inputs.type }}"
        PORT="${{ inputs.port }}"
        SUBDOMAIN="${{ inputs.subdomain }}"
        DOMAIN="ukkiee.dev"

        # type별 분기 설정
        # health path는 .app-config.yml의 health 필드에서 읽음 (아래에서 처리)
        HEALTH_PATH="${{ inputs.health }}"

        case "$TYPE" in
          static)
            MEMORY_REQUEST="64Mi"
            MEMORY_LIMIT="128Mi"
            CPU_REQUEST="50m"
            CPU_LIMIT="100m"
            [ -z "$HEALTH_PATH" ] && HEALTH_PATH="/"
            ;;
          web)
            MEMORY_REQUEST="128Mi"
            MEMORY_LIMIT="256Mi"
            CPU_REQUEST="100m"
            CPU_LIMIT="200m"
            [ -z "$HEALTH_PATH" ] && HEALTH_PATH="/health"
            ;;
          worker)
            MEMORY_REQUEST="128Mi"
            MEMORY_LIMIT="256Mi"
            CPU_REQUEST="100m"
            CPU_LIMIT="200m"
            ;;
          *)
            echo "❌ Unknown type: $TYPE (static|web|worker)"
            exit 1
            ;;
        esac

        mkdir -p _homelab/manifests/apps/$APP

        # deployment.yaml (heredoc 컬럼 0 시작 — 들여쓰기 오염 방지)
        cat > _homelab/manifests/apps/$APP/deployment.yaml << EOF
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: $APP
          namespace: $APP
          labels:
            app.kubernetes.io/name: $APP
            app.kubernetes.io/version: latest
            app.kubernetes.io/component: $TYPE
            app.kubernetes.io/managed-by: argocd
        spec:
          replicas: 1
          selector:
            matchLabels:
              app.kubernetes.io/name: $APP
          strategy:
            type: RollingUpdate
            rollingUpdate:
              maxUnavailable: 0
              maxSurge: 1
          template:
            metadata:
              labels:
                app.kubernetes.io/name: $APP
                app.kubernetes.io/version: latest
            spec:
              securityContext:
                runAsNonRoot: true
                runAsUser: 1000
                fsGroup: 1000
              # imagePullSecrets 불필요 — K3s registries.yaml로 노드 레벨 인증
              containers:
                - name: $APP
                  image: ghcr.io/ukkiee-dev/$APP:latest
                  ports:
                    - containerPort: $PORT
                  resources:
                    requests:
                      memory: "$MEMORY_REQUEST"
                      cpu: "$CPU_REQUEST"
                    limits:
                      memory: "$MEMORY_LIMIT"
                      cpu: "$CPU_LIMIT"
                  livenessProbe:
                    httpGet:
                      path: $HEALTH_PATH
                      port: $PORT
                    initialDelaySeconds: 15
                    periodSeconds: 20
                    failureThreshold: 3
                  readinessProbe:
                    httpGet:
                      path: $HEALTH_PATH
                      port: $PORT
                    initialDelaySeconds: 5
                    periodSeconds: 10
                    failureThreshold: 3
        EOF

        # worker 타입은 Service/IngressRoute 불필요
        if [ "$TYPE" = "worker" ]; then
          cat > _homelab/manifests/apps/$APP/kustomization.yaml << EOF
        apiVersion: kustomize.config.k8s.io/v1beta1
        kind: Kustomization
        resources:
          - deployment.yaml
        EOF
          echo "✅ manifests 생성 완료 (type=worker, Service/IngressRoute 없음)"
        else

        # service.yaml
        cat > _homelab/manifests/apps/$APP/service.yaml << EOF
        apiVersion: v1
        kind: Service
        metadata:
          name: $APP
          namespace: $APP
          labels:
            app.kubernetes.io/name: $APP
        spec:
          selector:
            app.kubernetes.io/name: $APP
          ports:
            - port: $PORT
              targetPort: $PORT
        EOF

        # ingressroute.yaml
        # entryPoints: web + websecure (tunnel은 HTTP port 80 = web으로 전달)
        # middleware: traefik-system의 공통 middleware를 cross-namespace 참조
        cat > _homelab/manifests/apps/$APP/ingressroute.yaml << EOF
        apiVersion: traefik.io/v1alpha1
        kind: IngressRoute
        metadata:
          name: $APP
          namespace: $APP
          labels:
            app.kubernetes.io/name: $APP
        spec:
          entryPoints:
            - web
            - websecure
          routes:
            - match: Host(\`$SUBDOMAIN.$DOMAIN\`)
              kind: Rule
              middlewares:
                - name: security-headers
                  namespace: traefik-system
              services:
                - name: $APP
                  port: $PORT
          # tls 섹션 없음 — Traefik entryPoint 레벨의 와일드카드 인증서(*.ukkiee.dev) 사용
          # certResolver: cloudflare는 websecure-only IngressRoute(grafana 등)에서만 사용
        EOF

        # kustomization.yaml
        cat > _homelab/manifests/apps/$APP/kustomization.yaml << EOF
        apiVersion: kustomize.config.k8s.io/v1beta1
        kind: Kustomization
        resources:
          - deployment.yaml
          - service.yaml
          - ingressroute.yaml
        EOF

        echo "✅ manifests 생성 완료 (type=$TYPE)"
        fi   # worker 분기 종료

    - name: Create ArgoCD Application
      shell: bash
      run: |
        set -euo pipefail
        APP="${{ inputs.app-name }}"

        cat > _homelab/argocd/applications/apps/$APP.yaml << EOF
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: $APP
          namespace: argocd
          annotations:
            argocd.argoproj.io/sync-wave: "0"
        spec:
          project: default
          source:
            repoURL: https://github.com/ukkiee-dev/homelab.git
            targetRevision: HEAD
            path: manifests/apps/$APP
          destination:
            server: https://kubernetes.default.svc
            namespace: $APP
          syncPolicy:
            automated:
              prune: true
              selfHeal: true
            syncOptions:
              - CreateNamespace=true
            retry:
              limit: 3
              backoff:
                duration: 5s
                factor: 2
                maxDuration: 3m
        EOF

        echo "✅ ArgoCD Application 생성 완료"

    # ── Step 4: git commit & push (terraform 완료 후) ─────────────
    - name: Commit & Push
      shell: bash
      run: |
        set -euo pipefail
        cd _homelab
        git config user.email "deploy-bot@users.noreply.github.com"
        git config user.name "deploy-bot[bot]"

        # 명시적 경로 지정 (.terraform/, tfplan 등 git 오염 방지)
        git add manifests/ argocd/ terraform/apps.json

        if git diff --staged --quiet; then
          echo "⏭️  변경사항 없음, 커밋 스킵"
          exit 0
        fi

        # commit 먼저 분리 (retry 로직 버그 방지)
        git commit -m "feat: add ${{ inputs.app-name }} (${{ inputs.subdomain }}.ukkiee.dev)"

        # push만 retry (commit은 이미 완료)
        PUSHED=false
        for i in 1 2 3; do
          git rebase --abort 2>/dev/null || true   # 이전 실패한 rebase 정리
          git pull --rebase origin main && git push && PUSHED=true && break || {
            echo "⚠️  push 실패 ($i/3), ${i}*5초 후 재시도..."
            sleep $((i * 5))
          }
        done

        if [ "$PUSHED" != "true" ]; then
          echo "❌ 3회 retry 후에도 push 실패"
          exit 1
        fi

        echo "✅ homelab 레포 업데이트 완료"
```

> **검증 — Heredoc 들여쓰기**:
> `run: |` (YAML 블록 스칼라)가 공통 들여쓰기를 자동 제거하므로
> heredoc 내용은 YAML 들여쓰기와 무관하게 정상 출력됨.

> **검증 — 실행 순서**:
> `apps.json 수정 → terraform apply → 매니페스트 생성 → git push`
> DNS + Tunnel ingress가 완전히 등록된 후에 ArgoCD sync 시작.

> **검증 — GHCR 인증**:
> K3s registries.yaml에서 노드 레벨 인증 → Deployment에 `imagePullSecrets` 불필요.
> PreSync Job, `ghcr-pat-secret` 등 네임스페이스별 시크릿 관리 복잡도 제거.

> **검증 — git add 경로**:
> `git add manifests/ argocd/ terraform/apps.json`으로 명시.
> `.terraform/`, `tfplan`, `.terraform.lock.hcl` 등 terraform 아티팩트 커밋 방지.

> **검증 — 네임스페이스 전략**:
> 앱별 독립 NS 사용. Traefik이 `allowCrossNamespace: true`로 설정되어 있으므로
> 새 NS의 IngressRoute 자동 감시 + traefik-system 미들웨어 참조 가능.

> **검증 — concurrency 제약**:
> `concurrency: homelab-terraform`은 **레포 단위** 격리.
> 서로 다른 앱 레포에서 동시에 setup 트리거 시 terraform state 충돌 가능.
> homelab에서 여러 앱을 동시에 최초 생성하지 말 것 (순차 생성 권장).

---

### 2-2. reusable workflow: `_update-image.yml`

```yaml
# homelab/.github/workflows/_update-image.yml
name: Update Image Tag

on:
  workflow_call:
    inputs:
      app-name:
        type: string
        required: true
      image-tag:
        type: string
        required: true
    secrets:
      APP_ID:
        required: true
      APP_PRIVATE_KEY:
        required: true
      TELEGRAM_BOT_TOKEN:
        required: false
      TELEGRAM_CHAT_ID:
        required: false

jobs:
  update:
    runs-on: ubuntu-latest
    concurrency:
      group: homelab-manifest-update
      cancel-in-progress: false

    steps:
      - name: Generate token
        id: app-token
        uses: actions/create-github-app-token@v1
        with:
          app-id: ${{ secrets.APP_ID }}
          private-key: ${{ secrets.APP_PRIVATE_KEY }}
          owner: ukkiee-dev
          repositories: homelab

      - name: Checkout homelab
        uses: actions/checkout@v4
        with:
          repository: ukkiee-dev/homelab
          token: ${{ steps.app-token.outputs.token }}

      - name: Install yq
        uses: mikefarah/yq@v4

      - name: Update image tag (yq — sed 다중 매칭 위험 해소)
        run: |
          set -euo pipefail
          FILE="manifests/apps/${{ inputs.app-name }}/deployment.yaml"

          if [ ! -f "$FILE" ]; then
            echo "❌ 매니페스트 없음: $FILE"
            exit 1
          fi

          # yq로 정확한 경로 지정 (sed 다중 매칭 위험 해소)
          yq eval -i \
            '.spec.template.spec.containers[0].image = "ghcr.io/ukkiee-dev/${{ inputs.app-name }}:${{ inputs.image-tag }}"' \
            "$FILE"

          git config user.email "deploy-bot@users.noreply.github.com"
          git config user.name "deploy-bot[bot]"

          if git diff --quiet; then
            echo "⏭️  이미지 변경 없음"
            exit 0
          fi

          # commit 먼저, push만 retry
          git commit -am "chore: update ${{ inputs.app-name }} → ${{ inputs.image-tag }}"

          PUSHED=false
          for i in 1 2 3; do
            git rebase --abort 2>/dev/null || true
            git pull --rebase origin main && git push && PUSHED=true && break || {
              echo "⚠️  push 실패 ($i/3), 재시도..."
              sleep $((i * 5))
            }
          done

          if [ "$PUSHED" != "true" ]; then
            echo "❌ 3회 retry 후에도 push 실패"
            exit 1
          fi

      - name: Notify failure (Telegram)
        if: failure()
        run: |
          curl -s -X POST "https://api.telegram.org/bot${{ secrets.TELEGRAM_BOT_TOKEN }}/sendMessage" \
            -d chat_id="${{ secrets.TELEGRAM_CHAT_ID }}" \
            -d text="❌ 이미지 태그 갱신 실패: ${{ inputs.app-name }}%0A${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"
```

> **검증 — yq vs sed**:
> sed는 `image:` 가 여러 곳에 있으면 모두 교체.
> yq는 `.spec.template.spec.containers[0].image` 경로를 정확히 지정.
> initContainer나 주석에 같은 이미지 문자열이 있어도 영향 없음.

---

### 2-3. teardown workflow (신규 — 롤백 자동화)

```yaml
# homelab/.github/workflows/teardown.yml
name: Teardown App

on:
  workflow_dispatch:
    inputs:
      app-name:
        description: "제거할 앱 이름"
        required: true
      subdomain:
        description: "앱 서브도메인 (예: blog) — 미입력 시 apps.json에서 자동 조회"
        required: false

jobs:
  teardown:
    runs-on: ubuntu-latest
    concurrency:
      group: homelab-terraform
      cancel-in-progress: false

    steps:
      - name: Generate token
        id: app-token
        uses: actions/create-github-app-token@v1
        with:
          app-id: ${{ secrets.HOMELAB_APP_ID }}
          private-key: ${{ secrets.HOMELAB_APP_PRIVATE_KEY }}
          owner: ukkiee-dev
          repositories: homelab

      - name: Checkout homelab
        uses: actions/checkout@v4
        with:
          repository: ukkiee-dev/homelab
          token: ${{ steps.app-token.outputs.token }}

      # ── Step 1: subdomain 조회 & apps.json에서 제거 ────────────
      - name: Remove from apps.json
        id: remove
        run: |
          set -euo pipefail
          APP="${{ inputs.app-name }}"

          # subdomain 자동 조회 (입력값 없으면 apps.json에서 추출)
          INPUT_SUB="${{ inputs.subdomain }}"
          if [ -z "$INPUT_SUB" ]; then
            INPUT_SUB=$(jq -r --arg name "$APP" '.[$name].subdomain // empty' terraform/apps.json)
          fi
          echo "subdomain=$INPUT_SUB" >> $GITHUB_OUTPUT

          jq --arg name "$APP" 'del(.[$name])' terraform/apps.json > /tmp/apps.json
          jq empty /tmp/apps.json
          mv /tmp/apps.json terraform/apps.json
          echo "✅ apps.json에서 $APP 제거 (subdomain: $INPUT_SUB)"

      # ── Step 2: Terraform (DNS + Tunnel 먼저 제거) ──────────────
      # git push 전에 실행 → terraform 실패 시 k8s 리소스는 유지됨
      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.7.0"

      - name: Terraform Init
        run: |
          terraform init \
            -backend-config="endpoint=https://${{ secrets.TF_ACCOUNT_ID }}.r2.cloudflarestorage.com" \
            -backend-config="access_key=${{ secrets.R2_ACCESS_KEY_ID }}" \
            -backend-config="secret_key=${{ secrets.R2_SECRET_ACCESS_KEY }}"
        working-directory: terraform

      - name: Terraform Plan (DNS + Tunnel ingress 제거 확인)
        run: terraform plan -out=tfplan
        working-directory: terraform
        env:
          TF_VAR_cloudflare_api_token: ${{ secrets.TF_CLOUDFLARE_TOKEN }}
          TF_VAR_zone_id:              ${{ secrets.TF_ZONE_ID }}
          TF_VAR_tunnel_id:            ${{ secrets.TF_TUNNEL_ID }}
          TF_VAR_account_id:           ${{ secrets.TF_ACCOUNT_ID }}

      - name: Terraform Apply
        run: terraform apply tfplan
        working-directory: terraform
        env:
          TF_VAR_cloudflare_api_token: ${{ secrets.TF_CLOUDFLARE_TOKEN }}
          TF_VAR_zone_id:              ${{ secrets.TF_ZONE_ID }}
          TF_VAR_tunnel_id:            ${{ secrets.TF_TUNNEL_ID }}
          TF_VAR_account_id:           ${{ secrets.TF_ACCOUNT_ID }}

      # ── Step 3: 매니페스트 제거 & git push (terraform 완료 후) ──
      - name: Remove manifests & ArgoCD Application
        run: |
          set -euo pipefail
          APP="${{ inputs.app-name }}"

          rm -rf manifests/apps/$APP
          rm -f argocd/applications/apps/$APP.yaml
          echo "✅ 매니페스트 제거 완료"

      - name: Commit & Push
        run: |
          set -euo pipefail
          git config user.email "deploy-bot@users.noreply.github.com"
          git config user.name "deploy-bot[bot]"
          git add manifests/ argocd/ terraform/apps.json
          git diff --staged --quiet && echo "변경사항 없음" && exit 0
          git commit -m "chore: remove ${{ inputs.app-name }}"
          git push
          echo "✅ ArgoCD prune으로 k8s 리소스 자동 삭제"

      - name: Notify success (Telegram)
        if: success()
        run: |
          curl -s -X POST "https://api.telegram.org/bot${{ secrets.TELEGRAM_BOT_TOKEN }}/sendMessage" \
            -d chat_id="${{ secrets.TELEGRAM_CHAT_ID }}" \
            -d text="🗑️ 앱 제거 완료: ${{ inputs.app-name }} (${{ steps.remove.outputs.subdomain }}.ukkiee.dev)"

      - name: Notify failure (Telegram)
        if: failure()
        run: |
          curl -s -X POST "https://api.telegram.org/bot${{ secrets.TELEGRAM_BOT_TOKEN }}/sendMessage" \
            -d chat_id="${{ secrets.TELEGRAM_CHAT_ID }}" \
            -d text="❌ Teardown 실패: ${{ inputs.app-name }}%0A${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"
```

> **검증 — teardown 순서 (setup과 대칭)**:
> 생성: `apps.json 수정 → terraform apply → 매니페스트 생성 → git push`
> 삭제: `apps.json 수정 → terraform apply → 매니페스트 삭제 → git push`
> terraform 실패 시 k8s 리소스는 유지됨 (안전 측 오류).
> 네임스페이스는 ArgoCD가 `CreateNamespace=true`로 생성하지만 prune 대상이 아님.
> 수동 정리: `kubectl delete namespace <app-name> --ignore-not-found`

---

## Phase 3 — Template 레포 구성

### `ci.yml` — 4개 job 순차 실행

```yaml
# .github/workflows/ci.yml
name: CI/CD

on:
  push:
    branches: [main]

jobs:
  # ── Job 1: 설정 파싱 & 세팅 여부 확인 ───────────────────────
  check:
    runs-on: ubuntu-latest
    outputs:
      already-setup: ${{ steps.check.outputs.exists }}
      app-name:      ${{ github.event.repository.name }}
      type:          ${{ steps.config.outputs.type }}
      port:          ${{ steps.config.outputs.port }}
      subdomain:     ${{ steps.config.outputs.subdomain }}
      health:        ${{ steps.config.outputs.health }}

    steps:
      - uses: actions/checkout@v4

      - name: Install yq
        uses: mikefarah/yq@v4

      - name: Parse .app-config.yml
        id: config
        run: |
          set -euo pipefail
          TYPE=$(yq '.type' .app-config.yml)
          PORT=$(yq '.port' .app-config.yml)
          SUBDOMAIN=$(yq '.subdomain' .app-config.yml)
          HEALTH=$(yq '.health // ""' .app-config.yml)

          # 유효성 검증: type
          if [[ ! "$TYPE" =~ ^(static|web|worker)$ ]]; then
            echo "❌ type 오류: '$TYPE' (static|web|worker 중 하나여야 함)"
            exit 1
          fi

          # worker는 port/subdomain/health 불필요
          if [ "$TYPE" = "worker" ]; then
            PORT="0"
            SUBDOMAIN=""
            HEALTH=""
          else
            if [ -z "$SUBDOMAIN" ] || [ "$SUBDOMAIN" = "null" ] || [ "$SUBDOMAIN" = '""' ]; then
              SUBDOMAIN="${{ github.event.repository.name }}"
            fi

            # 유효성 검증: port (숫자, 1-65535 범위)
            if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
              echo "❌ port 오류: '$PORT' (1-65535 범위의 숫자여야 함)"
              exit 1
            fi
          fi

          echo "type=$TYPE"           >> $GITHUB_OUTPUT
          echo "port=$PORT"           >> $GITHUB_OUTPUT
          echo "subdomain=$SUBDOMAIN" >> $GITHUB_OUTPUT
          echo "health=$HEALTH"       >> $GITHUB_OUTPUT
          echo "📋 type=$TYPE, port=$PORT, subdomain=$SUBDOMAIN, health=$HEALTH"

      - name: Generate token
        id: app-token
        uses: actions/create-github-app-token@v1
        with:
          app-id: ${{ secrets.HOMELAB_APP_ID }}
          private-key: ${{ secrets.HOMELAB_APP_PRIVATE_KEY }}
          owner: ukkiee-dev
          repositories: homelab

      - name: Check if already setup
        id: check
        run: |
          APP="${{ github.event.repository.name }}"
          STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
            -H "Authorization: Bearer ${{ steps.app-token.outputs.token }}" \
            "https://api.github.com/repos/ukkiee-dev/homelab/contents/manifests/apps/$APP/deployment.yaml")
          EXISTS=$([ "$STATUS" = "200" ] && echo "true" || echo "false")
          echo "exists=$EXISTS" >> $GITHUB_OUTPUT
          echo "📡 매니페스트 상태: HTTP $STATUS (exists=$EXISTS)"

  # ── Job 2: homelab 세팅 (최초 1회) ──────────────────────────
  setup:
    needs: check
    if: needs.check.outputs.already-setup == 'false'
    runs-on: ubuntu-latest
    concurrency:
      group: homelab-terraform
      cancel-in-progress: false

    steps:
      - name: Generate token
        id: app-token
        uses: actions/create-github-app-token@v1
        with:
          app-id: ${{ secrets.HOMELAB_APP_ID }}
          private-key: ${{ secrets.HOMELAB_APP_PRIVATE_KEY }}
          owner: ukkiee-dev
          repositories: homelab

      - name: Run setup
        uses: ukkiee-dev/homelab/.github/actions/setup-app@main
        with:
          app-name:             ${{ needs.check.outputs.app-name }}
          type:                 ${{ needs.check.outputs.type }}
          port:                 ${{ needs.check.outputs.port }}
          subdomain:            ${{ needs.check.outputs.subdomain }}
          health:               ${{ needs.check.outputs.health }}
          app-token:            ${{ steps.app-token.outputs.token }}
          tf-cloudflare-token:  ${{ secrets.TF_CLOUDFLARE_TOKEN }}
          tf-zone-id:           ${{ secrets.TF_ZONE_ID }}
          tf-tunnel-id:         ${{ secrets.TF_TUNNEL_ID }}
          tf-account-id:        ${{ secrets.TF_ACCOUNT_ID }}
          r2-access-key-id:     ${{ secrets.R2_ACCESS_KEY_ID }}
          r2-secret-access-key: ${{ secrets.R2_SECRET_ACCESS_KEY }}

      - name: Notify failure (Telegram)
        if: failure()
        run: |
          curl -s -X POST "https://api.telegram.org/bot${{ secrets.TELEGRAM_BOT_TOKEN }}/sendMessage" \
            -d chat_id="${{ secrets.TELEGRAM_CHAT_ID }}" \
            -d text="❌ Setup 실패: ${{ needs.check.outputs.app-name }}%0A${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"

  # ── Job 3: 빌드 & GHCR 푸시 ─────────────────────────────────
  deploy:
    needs: [check, setup]
    if: |
      always() &&
      needs.check.result == 'success' &&
      (needs.setup.result == 'success' || needs.setup.result == 'skipped')
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - uses: actions/checkout@v4

      - name: Login to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build & Push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ghcr.io/ukkiee-dev/${{ needs.check.outputs.app-name }}:latest
            ghcr.io/ukkiee-dev/${{ needs.check.outputs.app-name }}:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Notify failure (Telegram)
        if: failure()
        run: |
          curl -s -X POST "https://api.telegram.org/bot${{ secrets.TELEGRAM_BOT_TOKEN }}/sendMessage" \
            -d chat_id="${{ secrets.TELEGRAM_CHAT_ID }}" \
            -d text="❌ 빌드 실패: ${{ needs.check.outputs.app-name }}%0A${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"

  # ── Job 4: 이미지 태그 갱신 → ArgoCD 배포 ───────────────────
  # reusable workflow는 job level에서만 호출 가능 (step level 불가)
  update-manifest:
    needs: [check, deploy]
    if: always() && needs.deploy.result == 'success'
    uses: ukkiee-dev/homelab/.github/workflows/_update-image.yml@main
    with:
      app-name:  ${{ needs.check.outputs.app-name }}
      image-tag: ${{ github.sha }}
    secrets:
      APP_ID:              ${{ secrets.HOMELAB_APP_ID }}
      APP_PRIVATE_KEY:     ${{ secrets.HOMELAB_APP_PRIVATE_KEY }}
      TELEGRAM_BOT_TOKEN:  ${{ secrets.TELEGRAM_BOT_TOKEN }}
      TELEGRAM_CHAT_ID:    ${{ secrets.TELEGRAM_CHAT_ID }}
```

---

### `.app-config.yml` 스펙

```yaml
# .app-config.yml
# 수정이 필요한 파일은 이것뿐
type: web          # static | web | worker
port: 3000         # 컨테이너 포트 (worker는 불필요)
subdomain: ""      # 비워두면 레포 이름 사용 (my-blog → my-blog.ukkiee.dev)
health: /health    # 헬스체크 경로 (비워두면 type 기본값: static=/, web=/health)
```

---

### 템플릿별 차이

| | template-static | template-web |
|---|---|---|
| type | static | web |
| 기본 포트 | 8080 | 3000 |
| 베이스 이미지 | nginxinc/nginx-unprivileged | node:alpine (또는 사용자 정의) |
| 빌드 결과 | dist/ | 프레임워크별 상이 |
| 예시 스택 | React+Vite, Vue, Astro | Next.js, Express, Fastify, Go, Python |
| nginx.conf | 필요 (`listen 8080;` + `try_files`) | 불필요 |
| 헬스체크 기본값 | `/` | `/health` |
| 메모리 request | 64Mi | 128Mi |

> **static 포트**: `runAsNonRoot: true` + `runAsUser: 1000` 설정 시
> 표준 `nginx:alpine`은 port 80 바인딩 불가. `nginxinc/nginx-unprivileged` (8080) 사용.
>
> **worker** 템플릿은 필요 시 추가. Service/IngressRoute/DNS 없이 Deployment만 생성.

---

## Phase 4 — 검증

### 시나리오 1: 최초 배포

```
□ template-web 기반으로 test-blog 레포 생성
□ 로컬 clone
□ .app-config.yml → subdomain: blog 수정
□ git commit -m "init" && git push

Actions 탭 확인:
  □ check job
      □ type=web, port=3000, subdomain=blog 파싱 정상
      □ homelab API → HTTP 404 → already-setup=false
  □ setup job (순서 중요)
      □ apps.json에 test-blog 추가
      □ terraform plan: +1 cloudflare_record, tunnel ingress 추가 확인
      □ terraform apply 성공 (DNS + Tunnel 등록 완료)
      □ 매니페스트 생성 (type=web 분기 적용 확인)
      □ ArgoCD Application 생성 (retry 설정 포함)
      □ git push (terraform 완료 후)
  □ deploy job: GHCR 푸시 확인
  □ update-manifest job: deployment.yaml 태그 갱신 확인

클러스터 확인:
  □ ArgoCD UI에 test-blog Application 나타남
  □ K3s registries.yaml로 GHCR pull 정상 (imagePullSecrets 불필요)
  □ kubectl get pods -n test-blog → Running
  □ https://blog.ukkiee.dev → 접속 가능
```

### 시나리오 2: 이후 코드 변경

```
□ 코드 수정 & git push

  □ check: HTTP 200 → already-setup=true
  □ setup: 스킵
  □ deploy: 빌드 & GHCR 푸시
  □ update-manifest: yq로 정확한 경로 이미지 태그 갱신
  □ ArgoCD: 최대 3분 내 자동 배포
```

### 시나리오 3: 멱등성 확인

```
□ setup job 수동 재실행:
  □ apps.json: has() 확인 → 스킵
  □ terraform: No changes (이미 등록됨)
  □ manifests: 내용 동일 → git diff 없음 → 커밋 스킵
```

### 시나리오 4: setup 부분 실패 복구

```
terraform apply 실패 시:
  □ 상태: apps.json 수정됨, DNS/Tunnel 미등록, 매니페스트 미생성
  □ 복구: setup job 수동 재실행
          → apps.json: 멱등성으로 스킵
          → terraform: apps.json 기반 재시도
          → 이후 단계 정상 진행
```

### 시나리오 5: 앱 제거 (teardown)

```
□ homelab 레포 → Actions → teardown.yml
  → Run workflow → app-name: test-blog, subdomain: blog

자동으로 진행 (setup과 대칭 순서):
  □ apps.json에서 test-blog 제거
  □ terraform apply → DNS CNAME 삭제 + Tunnel ingress rule 삭제
  □ manifests/apps/test-blog/ 제거
  □ argocd/applications/apps/test-blog.yaml 제거
  □ git push → ArgoCD prune으로 k8s 리소스 삭제
  □ Telegram 알림: 제거 완료
  □ (수동) kubectl delete namespace test-blog --ignore-not-found
```

### 시나리오 6: worker 타입 배포

```
□ template-web 기반으로 my-queue-worker 레포 생성
□ .app-config.yml 수정:
    type: worker
    (port, subdomain, health 생략 또는 비움)
□ git push

Actions 탭 확인:
  □ check job
      □ type=worker 감지 → port/subdomain/health 기본값 설정
  □ setup job
      □ apps.json 수정: 스킵 (worker는 DNS 불필요)
      □ terraform: 스킵 (DNS/Tunnel 불필요)
      □ 매니페스트: deployment.yaml만 생성 (Service/IngressRoute 없음)
      □ ArgoCD Application 생성
      □ git push
  □ deploy: Docker 빌드 & GHCR 푸시 (동일)
  □ update-manifest: 이미지 태그 갱신 (동일)

클러스터 확인:
  □ kubectl get pods -n my-queue-worker → Running
  □ Service/IngressRoute 없음 확인
  □ Cloudflare DNS에 my-queue-worker 레코드 없음 확인
```

### 시나리오 7: worker 타입 제거

```
□ homelab 레포 → Actions → teardown → app-name: my-queue-worker

자동 진행:
  □ apps.json에 없음 감지 → terraform 스킵
  □ 매니페스트 제거 + git push
  □ ArgoCD prune으로 pod 삭제
```

---

## Phase 5 — 네임스페이스 전략 주의사항

독립 NS 방식 사용 시 반드시 확인:

```bash
# Traefik이 새 NS의 IngressRoute를 감시하는지 확인
kubectl get clusterrole traefik -o yaml | grep -A5 "ingressroutes"
# ClusterRole이면 모든 NS 자동 감시 ✅
# Role이면 각 NS에 RoleBinding 추가 필요

# NetworkPolicy 확인 (기존 policy가 apps NS 기준이면 새 앱에 미적용)
kubectl get networkpolicy -n apps
# 새 앱 NS에도 동일 policy 적용 필요 시 kustomization에 추가
```

---

## 구현 순서

```
Phase 1  사전 준비 (1회성)
  ├─ 1-1. GitHub App 생성 & homelab 레포에 설치
  ├─ 1-2. Org Secrets 등록 (10개)
  ├─ 1-3. K3s registries.yaml GHCR 인증 설정
  ├─ 1-4. R2 버킷 & API Token 발급
  └─ 1-5. homelab terraform 초기 설정 & apply (수동 1회)
           ├─ tunnel.tf 추가 후 기존 ingress rule 마이그레이션 확인
           └─ ⚠️ 기존 DNS/Tunnel 리소스 terraform import 필수

Phase 2  homelab 설정
  ├─ 2-1. .github/actions/setup-app/action.yml
  ├─ 2-2. .github/workflows/_update-image.yml
  └─ 2-3. .github/workflows/teardown.yml

Phase 3  Template 레포 구성
  ├─ 3-1. template-static (nginx, SPA/SSG)
  └─ 3-2. template-web (HTTP 서버, 언어 무관)

Phase 4  검증
  ├─ 4-1. 시나리오 1: 최초 배포
  ├─ 4-2. 시나리오 2: 이후 배포
  ├─ 4-3. 시나리오 3: 멱등성
  ├─ 4-4. 시나리오 4: 부분 실패 복구
  ├─ 4-5. 시나리오 5: teardown
  ├─ 4-6. 시나리오 6: worker 배포
  └─ 4-7. 시나리오 7: worker 제거

Phase 5  네임스페이스 전략 확인
  └─ 5-1. Traefik RBAC & NetworkPolicy 검증
```

> **⚠️ Phase 1-5 주의**:
> 1. `tunnel.tf`는 전체 tunnel config를 덮어씀. 현재 tunnel 경유 앱은 photos(immich) 1개뿐.
>    apps.json에 이것만 포함되어 있으면 기존 서비스에 영향 없음.
> 2. Tailscale A 레코드 앱(grafana, adguard 등 7개)은 terraform 범위 밖 — 절대 apps.json에 추가하지 말 것.
> 3. 기존 photos CNAME + tunnel config를 `terraform import`로 state에 가져와야 함.

---

## 완성 후 DX

```bash
# 1. GitHub에서 template-web → Use this template → my-blog 생성

# 2. 로컬
git clone https://github.com/ukkiee-dev/my-blog && cd my-blog

# 3. (선택) 서브도메인 커스텀
#    .app-config.yml → subdomain: blog

# 4. push
git add . && git commit -m "init" && git push

# 자동 진행
# ✅ check:           세팅 여부 확인
# ✅ setup:           apps.json → terraform (DNS+Tunnel) → 매니페스트 → git push
# ✅ deploy:          Docker 빌드 & GHCR 푸시
# ✅ update-manifest: 이미지 태그 yq 갱신
# ✅ ArgoCD:          자동 배포 (K3s registries.yaml로 GHCR pull)

# 앱 제거 시
# homelab 레포 → Actions → teardown → app-name 입력 → 모든 리소스 자동 삭제
```
