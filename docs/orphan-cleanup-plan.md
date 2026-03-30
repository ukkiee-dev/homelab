# 앱 제거 자동화 및 고아 리소스 정리 계획

## 배경

현재 앱 제거 시 teardown workflow가 DNS, manifests, ArgoCD Application만 정리하고 K8s Namespace과 GHCR 패키지는 수동 삭제가 필요하다. 또한 teardown을 실행하지 않고 레포를 삭제하면 모든 리소스가 잔존한다.

---

## 변경 1: teardown을 완전한 정리로 만들기

### 1-1. ArgoCD Application에 finalizer 추가

**변경 파일**: `.github/actions/setup-app/action.yml`

ArgoCD Application 생성 템플릿에 finalizer를 추가하면, Application이 삭제될 때 하위 K8s 리소스와 Namespace까지 자동 정리된다.

```yaml
metadata:
  name: $APP
  namespace: argocd
  finalizers:                                              # ← 추가
    - resources-finalizer.argocd.argoproj.io               # ← 추가
  annotations:
    argocd.argoproj.io/sync-wave: "0"
```

- `resources-finalizer.argocd.argoproj.io`: Application 삭제 시 관리하는 K8s 리소스를 모두 cascade delete
- `CreateNamespace=true`로 생성된 Namespace도 이 finalizer가 정리함

> 기존에 이미 배포된 앱(immich, test-blog 등)은 ArgoCD Application YAML에 수동으로 finalizer를 추가해야 적용됨.

### 1-2. teardown에 GHCR 패키지 삭제 step 추가

**변경 파일**: `.github/workflows/teardown.yml`

manifests 제거 step 이후, Commit & Push 이전에 추가:

```yaml
    # ── Step 3.5: GHCR 패키지 삭제 ──────────────────────────────
    - name: Delete GHCR package
      continue-on-error: true
      env:
        GH_TOKEN: ${{ steps.app-token.outputs.token }}
        APP_NAME: ${{ inputs.app-name }}
      run: |
        gh api "orgs/ukkiee-dev/packages/container/${APP_NAME}" -X DELETE \
          && echo "✅ GHCR 패키지 삭제 완료" \
          || echo "⏭️  GHCR 패키지 없음 또는 삭제 실패 (무시)"
```

> GitHub App 토큰에 `packages:write` 권한이 필요. 현재 `ukkiee-deploy-bot` App에 권한 추가 필요.

### 1-3. 변경 후 teardown 정리 범위

| 리소스 | 변경 전 | 변경 후 |
|---|---|---|
| DNS CNAME | 자동 ✅ | 자동 ✅ |
| Tunnel Ingress | 수동 ❌ → API ✅ | 자동 ✅ |
| K8s Deployment/Service | 자동 ✅ | 자동 ✅ |
| K8s Namespace | **수동** ❌ | **자동** ✅ (finalizer) |
| GHCR Package | **수동** ❌ | **자동** ✅ (gh api) |
| ArgoCD Application | 자동 ✅ | 자동 ✅ |

---

## 변경 2: 고아 앱 감사 cron workflow

### 목적

teardown 없이 레포가 삭제된 경우를 감지하여 Telegram 알림 + 구체적인 대응 방법을 안내한다.

### 감사 대상

1. **고아 앱**: homelab에 manifests가 있지만 앱 레포가 존재하지 않는 경우
2. **Tunnel drift**: apps.json 엔트리와 tunnel ingress rule이 불일치하는 경우

### Workflow

**새 파일**: `.github/workflows/audit-orphans.yml`

```yaml
name: Audit Orphaned Apps

on:
  schedule:
    - cron: '0 0 * * 1'  # 매주 월요일 00:00 UTC (KST 09:00)
  workflow_dispatch:       # 수동 실행도 가능

jobs:
  audit:
    runs-on: ubuntu-latest
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
          token: ${{ steps.app-token.outputs.token }}

      - name: Audit orphaned apps
        id: audit
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
        run: |
          set -euo pipefail

          ORPHANS=""
          ORPHAN_COUNT=0

          for APP_DIR in manifests/apps/*/; do
            APP=$(basename "$APP_DIR")

            # 앱 레포 존재 여부 확인
            if ! gh api "repos/ukkiee-dev/${APP}" --silent 2>/dev/null; then
              ORPHANS="${ORPHANS}• ${APP}\n"
              ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
            fi
          done

          echo "orphan_count=$ORPHAN_COUNT" >> $GITHUB_OUTPUT

          if [ "$ORPHAN_COUNT" -gt 0 ]; then
            # 줄바꿈을 GitHub Output에 안전하게 전달
            {
              echo "orphan_list<<EOF"
              echo -e "$ORPHANS"
              echo "EOF"
            } >> $GITHUB_OUTPUT
            echo "🚨 고아 앱 ${ORPHAN_COUNT}개 발견"
          else
            echo "✅ 고아 앱 없음"
          fi

      - name: Audit tunnel config drift
        id: tunnel-audit
        if: always()
        env:
          CF_TOKEN: ${{ secrets.TF_CLOUDFLARE_TOKEN }}
          ACCOUNT_ID: ${{ secrets.TF_ACCOUNT_ID }}
          TUNNEL_ID: ${{ secrets.TF_TUNNEL_ID }}
          DOMAIN: ${{ secrets.TF_DOMAIN }}
        run: |
          set -euo pipefail

          # apps.json에서 예상 hostname 목록
          EXPECTED=$(jq -r '.[].subdomain' terraform/apps.json | sort)

          # Tunnel API에서 실제 hostname 목록
          API_URL="https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations"
          RESPONSE=$(curl -sf --connect-timeout 10 --max-time 30 \
            -H "Authorization: Bearer $CF_TOKEN" "$API_URL")

          ACTUAL=$(echo "$RESPONSE" | jq -r \
            '.result.config.ingress[] | select(.hostname) | .hostname' \
            | sed "s/\.${DOMAIN}//" | sort)

          # 차이 비교
          ONLY_DNS=$(comm -23 <(echo "$EXPECTED") <(echo "$ACTUAL"))
          ONLY_TUNNEL=$(comm -13 <(echo "$EXPECTED") <(echo "$ACTUAL"))

          DRIFT=""
          if [ -n "$ONLY_DNS" ]; then
            DRIFT="${DRIFT}DNS에만 있음 (tunnel 누락):\n"
            while IFS= read -r sub; do
              DRIFT="${DRIFT}• ${sub}.${DOMAIN}\n"
            done <<< "$ONLY_DNS"
          fi
          if [ -n "$ONLY_TUNNEL" ]; then
            DRIFT="${DRIFT}Tunnel에만 있음 (DNS 누락):\n"
            while IFS= read -r sub; do
              DRIFT="${DRIFT}• ${sub}.${DOMAIN}\n"
            done <<< "$ONLY_TUNNEL"
          fi

          if [ -n "$DRIFT" ]; then
            {
              echo "drift<<EOF"
              echo -e "$DRIFT"
              echo "EOF"
            } >> $GITHUB_OUTPUT
            echo "has_drift=true" >> $GITHUB_OUTPUT
            echo "🚨 Tunnel config drift 발견"
          else
            echo "has_drift=false" >> $GITHUB_OUTPUT
            echo "✅ Tunnel config 일치"
          fi

      - name: Send Telegram alert
        if: steps.audit.outputs.orphan_count != '0' || steps.tunnel-audit.outputs.has_drift == 'true'
        env:
          TG_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TG_CHAT: ${{ secrets.TELEGRAM_CHAT_ID }}
          ORPHAN_COUNT: ${{ steps.audit.outputs.orphan_count }}
          ORPHAN_LIST: ${{ steps.audit.outputs.orphan_list }}
          HAS_DRIFT: ${{ steps.tunnel-audit.outputs.has_drift }}
          DRIFT: ${{ steps.tunnel-audit.outputs.drift }}
          RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
        run: |
          MSG="🔍 주간 인프라 감사 결과%0A"

          if [ "$ORPHAN_COUNT" != "0" ]; then
            MSG="${MSG}%0A🚨 고아 앱 ${ORPHAN_COUNT}개 (레포 삭제됨, teardown 안 됨):%0A"
            # ORPHAN_LIST의 줄바꿈을 URL-encode
            ENCODED_LIST=$(echo -e "$ORPHAN_LIST" | sed 's/$/%0A/g' | tr -d '\n')
            MSG="${MSG}${ENCODED_LIST}"
            MSG="${MSG}%0A📋 정리 방법:%0A"
            MSG="${MSG}gh workflow run teardown.yml -f app-name=<앱이름>%0A"
          fi

          if [ "$HAS_DRIFT" = "true" ]; then
            MSG="${MSG}%0A⚠️ Tunnel config drift:%0A"
            ENCODED_DRIFT=$(echo -e "$DRIFT" | sed 's/$/%0A/g' | tr -d '\n')
            MSG="${MSG}${ENCODED_DRIFT}"
            MSG="${MSG}%0A📋 정리 방법:%0A"
            MSG="${MSG}manage-tunnel-ingress.sh list 로 확인 후%0A"
            MSG="${MSG}manage-tunnel-ingress.sh remove <hostname> 으로 제거%0A"
          fi

          MSG="${MSG}%0A🔗 ${RUN_URL}"

          curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT}" \
            -d parse_mode="HTML" \
            -d text="$MSG"

      - name: Send Telegram OK (no issues)
        if: steps.audit.outputs.orphan_count == '0' && steps.tunnel-audit.outputs.has_drift != 'true'
        env:
          TG_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TG_CHAT: ${{ secrets.TELEGRAM_CHAT_ID }}
        run: |
          curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT}" \
            -d text="✅ 주간 인프라 감사: 이상 없음"
```

### 알림 예시

**고아 앱 발견 시**:
```
🔍 주간 인프라 감사 결과

🚨 고아 앱 2개 (레포 삭제됨, teardown 안 됨):
• old-project
• deprecated-api

📋 정리 방법:
gh workflow run teardown.yml -f app-name=<앱이름>

🔗 https://github.com/ukkiee-dev/homelab/actions/runs/12345
```

**Tunnel drift 발견 시**:
```
🔍 주간 인프라 감사 결과

⚠️ Tunnel config drift:
DNS에만 있음 (tunnel 누락):
• new-app.ukkiee.dev

Tunnel에만 있음 (DNS 누락):
• removed-app.ukkiee.dev

📋 정리 방법:
manage-tunnel-ingress.sh list 로 확인 후
manage-tunnel-ingress.sh remove <hostname> 으로 제거

🔗 https://github.com/ukkiee-dev/homelab/actions/runs/12345
```

**이상 없을 시**:
```
✅ 주간 인프라 감사: 이상 없음
```

---

## 앱 완전 제거 절차 (최종)

### 정상 경로

```
1. teardown workflow dispatch (app-name 입력)
   ├─ apps.json 제거
   ├─ Terraform apply (DNS CNAME 삭제)
   ├─ Tunnel API (ingress rule 제거)
   ├─ manifests/ + argocd/ 파일 삭제
   ├─ GHCR 패키지 삭제
   └─ git push → ArgoCD prune + finalizer → K8s 리소스 + NS 삭제
2. 앱 레포 삭제 (GitHub)
3. 끝. 수동 작업 없음.
```

### 비정상 경로 (teardown 안 하고 레포 삭제)

```
1. 주간 감사 workflow가 고아 앱 감지
2. Telegram 알림 수신 (앱 이름 + 대응 방법 포함)
3. teardown workflow 수동 실행
4. 정상 경로와 동일하게 정리됨
```

---

## 구현 순서

| 순서 | 작업 | 변경 파일 |
|---|---|---|
| 1 | ArgoCD Application에 finalizer 추가 | `.github/actions/setup-app/action.yml` |
| 2 | 기존 앱에 finalizer 수동 추가 | `argocd/applications/apps/*.yaml` |
| 3 | teardown에 GHCR 삭제 step 추가 | `.github/workflows/teardown.yml` |
| 4 | GitHub App에 `packages:write` 권한 추가 | GitHub 설정 |
| 5 | audit-orphans workflow 생성 | `.github/workflows/audit-orphans.yml` |
| 6 | tunnel API 마이그레이션 (별도 작업) | 마이그레이션 계획 v2 참조 |

---

## 주의사항

1. **finalizer 삭제 주의**: ArgoCD Application에 finalizer가 있으면 Application YAML을 Git에서 삭제할 때 cascade delete가 발동한다. 의도적 teardown이 아닌 실수로 삭제하면 서비스 중단.
   - 안전장치: ArgoCD `prune: true`로 이미 Git 삭제 → K8s 삭제 파이프라인이 구성되어 있으므로 finalizer 추가는 기존 동작의 연장선이다.

2. **GitHub App 권한**: `packages:write` 추가 시 Org 레벨 재승인 필요할 수 있음.

3. **감사 workflow의 오탐**:
   - 앱 레포가 private으로 전환되면 API 접근 실패 → 고아로 오탐
   - 앱 레포 이름이 manifest 디렉토리명과 다르면 오탐
   - 둘 다 현재 구조에서는 발생하지 않지만 (public only, 이름 일치) 문서로 남겨둠
