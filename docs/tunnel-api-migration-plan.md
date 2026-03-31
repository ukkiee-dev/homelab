# Cloudflare Tunnel Ingress 자동화 — API 직접 호출 방식 v7

<details>
<summary>버전 이력 (v1~v5)</summary>

### v1→v2: 토큰 보호, GET 검증, 멱등성, 타임아웃
### v2→v3: jq payload, 셸 인젝션 방지, catch-all 필터, GHCR 삭제, finalizer, 감사 workflow
### v3→v4 (3차 리뷰): 구현 순서, mktemp, catch-all 검증, 감사 개선

### v4→v5 (4차 리뷰 반영)

| # | 수정 | 심각도 |
|---|---|---|
| 6.1 | 구현 순서 수정: Phase 6(권한) → 1 → 2,3 → 4 → 7 → 5 | P1 |
| 3.1 | tunnel API 실패 시에도 apps.json은 push (DNS 삭제 방지) | P1 |
| 2.1 | `/tmp` 파일 경합 방지: mktemp + trap | P1 |
| 2.2 | catch-all 검증: 마지막 rule에 hostname 없는지 확인 | P1 |
| 5.1 | 감사 대상: apps.json 기반 + 제외 목록 (false positive 방지) | P2 |
| 4.1 | infra 앱에 finalizer 미적용 이유 문서화 | P2 |
| 4.2 | background finalizer 선택 이유 문서화 | P2 |
| 3.3 | GHCR 패키지 이름 = 앱 이름 규약 문서화 | P2 |
| 5.2 | tunnel drift sed 정규식 이스케이프 | P2 |
| 2.3 | service 변경 시 로그 메시지 정확하게 (add → update) | P3 |
| 4.3 | targetRevision `HEAD` → `main` 통일 | P3 |
| 6.2 | E2E 테스트에 finalizer/tunnel/GHCR 검증 추가 | P3 |
| 1.1 | 버전 이력 축소 (details 블록) | P3 |
| 1.2 | Phase 4~6을 "부속 개선"으로 분리 | P3 |

### v4→v5 추가 수정

| # | 수정 | 심각도 |
|---|---|---|
| 1.1 | 실행 순서 — "중단" → continue-on-error 반영 | P1 |
| 2.1 | ArgoCD Application step에도 tunnel 조건 추가 | P1 |
| 2.3 | setup-app output `tunnel-status` + 호출자 경고 알림 | P1 |
| 4.2 | `HOSTNAME` → `TUNNEL_HOSTNAME` (시스템 변수 충돌 방지) | P2 |
| 2.4 | 부분 setup 복구 절차 문서화 | P2 |
| 2.2 | 부분 setup 커밋 메시지 분기 | P2 |
| 4.1 | EXISTING_SERVICE 다중 hostname 방어 `[0]` | P2 |
| 3.1 | 기존 step 셸 인젝션 벡터 기록 | P2 |
| 1.2 | 이중 수평선 삭제 | P3 |

</details>

### v5 → v6 (5차 리뷰 반영)

| # | 수정 | 심각도 |
|---|---|---|
| 1 | Commit & Push step 수정 코드를 Phase 2에 추가 | P1 |
| 2.1 | 앱 레포 CI 템플릿에 `id: setup` 요구사항 명시 | P1 |
| 2.3 | "check job" 복구 경로 설명 구체화 (이미 구현됨 명시) | P2 |
| 3 | 버전 이력 전체를 details 블록으로 이동 | P3 |
| 4.2 | 부분 setup 복구 테스트 시나리오 추가 | P3 |

### v6 → v7 (6차 리뷰 반영)

| # | 수정 | 심각도 |
|---|---|---|
| 1 | tunnel 실패 시 update-manifest 스킵 (job-level output + 조건) | P2 |
| 2 | 구현 순서에 앱 레포 CI / template-web 변경 항목 추가 | P2 |

---

## 배경

### 문제
`tunnel.tf`(Terraform)로 tunnel config을 관리하면 **전체 교체(replace)** 방식으로 동작하여:
1. 매 apply마다 tunnel 라우팅이 재설정 → 502 발생
2. Cloudflare 대시보드와 state 충돌
3. 부분 수정 불가 (한 앱 추가 시 전체 config 덮어쓰기)

### 해결 방향
Terraform 대신 **Cloudflare API를 직접 호출**하여 tunnel ingress를 관리:
- GET (현재 config 조회) → 수정 → PUT (업데이트)
- 부분 수정 가능 (기존 rule 유지하면서 추가/삭제만)
- Terraform state 문제 없음

---

## 현재 상태 vs 목표

| 리소스 | 현재 | 목표 |
|---|---|---|
| DNS CNAME | Terraform (자동) ✅ | 유지 |
| Tunnel Ingress | 대시보드 (수동) ❌ | **API (자동)** ✅ |
| K8s Manifests | setup-app (자동) ✅ | 유지 |

---

## 핵심 원칙

1. **GET 먼저** — 현재 config를 읽고 수정 (blind PUT 금지)
2. **GET 응답 검증** — HTTP 200 + config 파싱 + rule 개수 1개 이상
3. **catch-all 보존** — hostname이 없는 마지막 rule을 catch-all로 취급 (service 값 무관)
4. **중복 방지** — add: 동일 hostname+service면 스킵. hostname 같고 service 다르면 교체
5. **멱등성** — add: 이미 동일하면 스킵 (exit 0). remove: 없으면 스킵 (exit 0)
6. **토큰 보호** — CLI 인자 미사용, 환경변수로만 전달
7. **안전한 JSON 조립** — 셸 문자열 보간 대신 jq로 payload 생성

---

## 구현 계획

### Phase 1: 스크립트 작성

**`.github/scripts/manage-tunnel-ingress.sh`**:

```bash
#!/bin/bash
set -euo pipefail

# 환경변수 필수 확인 (CLI 인자로 토큰 전달 금지 — ps/proc 노출 방지)
: "${CF_TOKEN:?CF_TOKEN 환경변수 필요}"
: "${ACCOUNT_ID:?ACCOUNT_ID 환경변수 필요}"
: "${TUNNEL_ID:?TUNNEL_ID 환경변수 필요}"

ACTION="${1:?Usage: manage-tunnel-ingress.sh <add|remove|list> <hostname> [service]}"
HOSTNAME="${2:-}"
SERVICE="${3:-http://traefik:80}"

CURL_OPTS=(--connect-timeout 10 --max-time 30)
API_URL="https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations"

# 프로세스별 고유 임시 파일 (동시 실행 시 경합 방지)
TMPFILE=$(mktemp /tmp/tunnel-XXXXXX.json)
TMPFILE_PUT=$(mktemp /tmp/tunnel-put-XXXXXX.json)
trap 'rm -f "$TMPFILE" "$TMPFILE_PUT"' EXIT

# 1. 현재 config 조회 + 검증
echo "📡 현재 tunnel config 조회..."
HTTP_CODE=$(curl -s -o "$TMPFILE" -w '%{http_code}' "${CURL_OPTS[@]}" \
  -H "Authorization: Bearer $CF_TOKEN" "$API_URL") || {
  echo "❌ API 연결 실패"; exit 1
}
BODY=$(cat "$TMPFILE")

if [ "$HTTP_CODE" != "200" ]; then
  echo "❌ API 응답 HTTP $HTTP_CODE: $BODY"; exit 1
fi

CONFIG=$(echo "$BODY" | jq -e '.result.config') || {
  echo "❌ config 파싱 실패: $BODY"; exit 1
}

RULE_COUNT=$(echo "$CONFIG" | jq '.ingress | length')
if [ "$RULE_COUNT" -lt 1 ]; then
  echo "❌ ingress가 비어있음 — 비정상 상태"; exit 1
fi

# list 액션
if [ "$ACTION" = "list" ]; then
  echo "$CONFIG" | jq -r '.ingress[] | select(.hostname) | .hostname'
  exit 0
fi

# hostname 필수 (add/remove)
: "${HOSTNAME:?hostname 인자 필요}"

# hostname 유무로 catch-all 분리 (service 값 무관 — 대시보드에서 변경해도 보존)
RULES=$(echo "$CONFIG" | jq '[.ingress[] | select(.hostname)]')
CATCHALL=$(echo "$CONFIG" | jq '.ingress[-1]')

# catch-all 검증: 마지막 rule에 hostname이 있으면 비정상
CATCHALL_HAS_HOSTNAME=$(echo "$CATCHALL" | jq 'has("hostname")')
if [ "$CATCHALL_HAS_HOSTNAME" = "true" ]; then
  echo "❌ 마지막 ingress rule에 hostname이 있음 — catch-all 누락"
  echo "현재 config: $(echo "$CONFIG" | jq -c '.ingress')"
  exit 1
fi

BEFORE_COUNT=$(echo "$RULES" | jq 'length')

case "$ACTION" in
  add)
    EXISTING_SERVICE=$(echo "$RULES" | jq -r --arg h "$HOSTNAME" \
      '[.[] | select(.hostname == $h)][0].service // empty')
    if [ "$EXISTING_SERVICE" = "$SERVICE" ]; then
      echo "⏭️  $HOSTNAME 이미 동일한 service로 존재, 스킵"
      exit 0
    elif [ -n "$EXISTING_SERVICE" ]; then
      echo "🔄 $HOSTNAME service 변경: $EXISTING_SERVICE → $SERVICE"
      RULES=$(echo "$RULES" | jq --arg h "$HOSTNAME" '[.[] | select(.hostname != $h)]')
    fi
    NEW_RULE=$(jq -n --arg h "$HOSTNAME" --arg s "$SERVICE" '{hostname: $h, service: $s}')
    UPDATED=$(echo "$RULES" | jq --argjson rule "$NEW_RULE" '. + [$rule]')
    ;;
  remove)
    EXISTING=$(echo "$RULES" | jq --arg h "$HOSTNAME" '[.[] | select(.hostname == $h)] | length')
    if [ "$EXISTING" -eq 0 ]; then
      echo "⏭️  $HOSTNAME 없음, 스킵"
      exit 0
    fi
    UPDATED=$(echo "$RULES" | jq --arg h "$HOSTNAME" '[.[] | select(.hostname != $h)]')
    ;;
  *)
    echo "❌ Unknown action: $ACTION (add|remove|list)"; exit 1
    ;;
esac

AFTER_COUNT=$(echo "$UPDATED" | jq 'length')
echo "📊 ingress rules: $BEFORE_COUNT → $AFTER_COUNT"

# catch-all 재추가 + 최종 config 조립
FINAL_CONFIG=$(echo "$CONFIG" | jq --argjson rules "$UPDATED" --argjson catchall "$CATCHALL" \
  '.ingress = ($rules + [$catchall])')

# dry-run
if [ "${DRY_RUN:-false}" = "true" ]; then
  echo "🔍 [DRY-RUN] 변경될 config:"
  echo "$FINAL_CONFIG" | jq .
  exit 0
fi

# 2. config 업데이트 — payload를 jq로 안전하게 조립 (셸 문자열 보간 미사용)
echo "📡 tunnel config 업데이트..."
PAYLOAD=$(jq -n --argjson config "$FINAL_CONFIG" '{config: $config}')

PUT_CODE=$(curl -s -o "$TMPFILE_PUT" -w '%{http_code}' "${CURL_OPTS[@]}" \
  -X PUT "$API_URL" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD") || {
  echo "❌ PUT 요청 실패"; exit 1
}
PUT_BODY=$(cat "$TMPFILE_PUT")

if [ "$PUT_CODE" = "200" ] && echo "$PUT_BODY" | jq -e '.success' > /dev/null; then
  if [ -n "${EXISTING_SERVICE:-}" ] && [ "$EXISTING_SERVICE" != "$SERVICE" ]; then
    echo "✅ update 완료: $HOSTNAME ($EXISTING_SERVICE → $SERVICE)"
  else
    echo "✅ $ACTION 완료: $HOSTNAME"
  fi
else
  echo "❌ 업데이트 실패 (HTTP $PUT_CODE): $PUT_BODY"; exit 1
fi
```

### Phase 2: setup-app action 수정

**변경 위치**: terraform apply 이후, manifests 생성 이전

> **경로 `_homelab/`**: setup-app은 앱 레포의 CI에서 호출되며,
> homelab을 `_homelab/` 경로에 checkout함. teardown은 homelab 자체 workflow이므로 prefix 없음.

> **셸 인젝션 방지**: `${{ inputs.subdomain }}`을 직접 run 블록에 넣지 않고
> env로 전달하여 GitHub Actions가 안전하게 환경변수로 설정.

```yaml
    # ── Step 2.5: Tunnel Ingress 추가 (API 직접 호출) ────────────
    # continue-on-error: 실패해도 apps.json/terraform 변경은 push해야 함
    # (안 그러면 다른 앱 setup에서 이 앱의 DNS가 삭제됨)
    - name: Add tunnel ingress
      id: tunnel
      if: ${{ inputs.type != 'worker' }}
      continue-on-error: true
      shell: bash
      env:
        CF_TOKEN: ${{ inputs.tf-cloudflare-token }}
        ACCOUNT_ID: ${{ inputs.tf-account-id }}
        TUNNEL_ID: ${{ inputs.tf-tunnel-id }}
        TUNNEL_HOSTNAME: "${{ inputs.subdomain }}.${{ inputs.domain }}"
      run: |
        bash _homelab/.github/scripts/manage-tunnel-ingress.sh add "$TUNNEL_HOSTNAME"
```

> **tunnel 실패 시 전략**: apps.json + terraform 변경은 항상 push.
> manifests/ArgoCD 생성은 tunnel 성공 시에만 진행.
> 이유: push하지 않으면 다음 앱의 terraform이 이전 apps.json 기준으로 plan →
> 방금 추가한 DNS가 "삭제 대상"이 됨.

```yaml
    # ── Step 3: manifests + ArgoCD (tunnel 성공 시에만) ─────────
    - name: Create manifests
      if: ${{ steps.tunnel.outcome == 'success' || inputs.type == 'worker' }}
      ...

    - name: Create ArgoCD Application
      if: ${{ steps.tunnel.outcome == 'success' || inputs.type == 'worker' }}
      ...
```

**setup-app 추가 수정사항**:
- description: `Terraform(DNS) + Tunnel API + 매니페스트 생성 → git push`
- 주석: `Tunnel ingress는 Step 2.5에서 Cloudflare API로 자동 추가`
- ArgoCD Application: `targetRevision: main` (기존 앱과 통일, HEAD → main)
- output 추가: `tunnel-status` — tunnel API 결과를 호출자에게 노출

```yaml
# setup-app action.yml에 outputs 추가
outputs:
  tunnel-status:
    description: "tunnel API 결과 (success/failure)"
    value: ${{ steps.tunnel.outcome }}
```

**Commit & Push step 수정** (tunnel 결과에 따라 git add/커밋 메시지 분기 + 셸 인젝션 방지):
```yaml
    - name: Commit & Push
      shell: bash
      env:
        TUNNEL_OUTCOME: ${{ steps.tunnel.outcome }}
        APP_NAME: ${{ inputs.app-name }}
        SUBDOMAIN: ${{ inputs.subdomain }}
        DOMAIN: ${{ inputs.domain }}
        APP_TYPE: ${{ inputs.type }}
      run: |
        set -euo pipefail
        cd _homelab
        git config user.email "deploy-bot@users.noreply.github.com"
        git config user.name "deploy-bot[bot]"

        git add terraform/apps.json

        if [ "$TUNNEL_OUTCOME" = "success" ] || [ "$APP_TYPE" = "worker" ]; then
          git add manifests/ argocd/
        fi

        if git diff --staged --quiet; then
          echo "⏭️  변경사항 없음, 커밋 스킵"
          exit 0
        fi

        if [ "$APP_TYPE" = "worker" ]; then
          git commit -m "feat: add $APP_NAME (worker)"
        elif [ "$TUNNEL_OUTCOME" = "success" ]; then
          git commit -m "feat: add $APP_NAME ($SUBDOMAIN.$DOMAIN)"
        else
          git commit -m "feat: add DNS for $APP_NAME ($SUBDOMAIN.$DOMAIN) — tunnel 실패, manifests 미생성"
        fi

        PUSHED=false
        for i in 1 2 3; do
          git rebase --abort 2>/dev/null || true
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

**앱 레포 ci.yml 전제 조건** (template에 반영 필수):

1. setup-app 호출 step에 **`id: setup`** 추가 (output 접근에 필수):
```yaml
    - name: Run setup
      id: setup                  # ← 추가 필수
      uses: ukkiee-dev/homelab/.github/actions/setup-app@main
      with: ...
```

2. setup job에 **job-level output** 추가 (downstream job 조건 분기용):
```yaml
# 앱 레포 ci.yml
setup:
  needs: check
  outputs:
    tunnel-status: ${{ steps.setup.outputs.tunnel-status }}
  steps:
    - name: Run setup
      id: setup
      ...
```

3. 경고 step 추가:
```yaml
    - name: Warn on partial setup
      if: steps.setup.outputs.tunnel-status == 'failure'
      env:
        APP_NAME: ${{ needs.check.outputs.app-name }}
        TG_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
        TG_CHAT: ${{ secrets.TELEGRAM_CHAT_ID }}
      run: |
        echo "::warning::Tunnel API 실패 — DNS만 생성됨, 앱 접속 불가"
        curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
          -d chat_id="${TG_CHAT}" \
          -d text="⚠️ ${APP_NAME} 부분 setup — tunnel 실패, 재시도 필요"
```

4. **update-manifest job에 tunnel 실패 시 스킵 조건** 추가:

tunnel 실패 시 manifests가 없으므로 update-manifest가 불필요하게 실패하여
혼란스러운 알림("이미지 태그 갱신 실패")이 발생한다. deploy(이미지 빌드)는
나중에 manifests 생성 후 필요하므로 실행을 유지하되, update-manifest만 스킵:

```yaml
update-manifest:
  needs: [check, setup, deploy]
  if: |
    always() && needs.deploy.result == 'success' &&
    needs.setup.outputs.tunnel-status != 'failure'
```

### Phase 3: teardown workflow 수정

**변경 위치**: terraform apply 이후, manifests 제거 이전

```yaml
    # ── Step 2.5: Tunnel Ingress 제거 (API) ──────────────────────
    # teardown에서는 실패해도 계속 진행 (DNS 없으면 tunnel rule 잔존해도 실질적 영향 없음)
    - name: Remove tunnel ingress
      if: steps.remove.outputs.in_apps_json == 'true'
      continue-on-error: true
      env:
        CF_TOKEN: ${{ secrets.TF_CLOUDFLARE_TOKEN }}
        ACCOUNT_ID: ${{ secrets.TF_ACCOUNT_ID }}
        TUNNEL_ID: ${{ secrets.TF_TUNNEL_ID }}
        TUNNEL_HOSTNAME: "${{ steps.remove.outputs.subdomain }}.${{ secrets.TF_DOMAIN }}"
      run: |
        bash .github/scripts/manage-tunnel-ingress.sh remove "$TUNNEL_HOSTNAME"

    # ── Step 2.6: GHCR 패키지 삭제 ──────────────────────────────
    - name: Delete GHCR package
      continue-on-error: true
      env:
        GH_TOKEN: ${{ steps.app-token.outputs.token }}
        APP_NAME: ${{ inputs.app-name }}
      run: |
        gh api "orgs/ukkiee-dev/packages/container/${APP_NAME}" -X DELETE \
          && echo "✅ GHCR 패키지 삭제" \
          || echo "⏭️  GHCR 패키지 없음 또는 권한 부족 (무시)"
```

> GHCR 패키지 삭제는 GitHub App에 `packages:write` 권한이 필요.
> 권한이 없으면 실패하지만 `continue-on-error: true`로 무시.

---

## 실행 순서 (최종)

### 앱 생성 (setup)
```
1. apps.json 업데이트
2. Terraform apply (DNS CNAME 생성)
3. Tunnel Ingress API (hostname 추가)     ← continue-on-error
   ├─ 성공: manifests + ArgoCD 생성 → git push (완전 setup)
   └─ 실패: apps.json/DNS만 push (부분 setup), manifests는 다음 CI에서 재시도
4. K8s 매니페스트 생성 (tunnel 성공 시에만)
5. ArgoCD Application 생성 (tunnel 성공 시에만)
6. git push (항상 — apps.json/terraform 변경 보호)
```

### 앱 제거 (teardown) — **반드시 레포 삭제 전에 실행**
```
1. apps.json에서 제거
2. Terraform apply (DNS CNAME 삭제)
3. Tunnel Ingress API (hostname 제거)     ← 실패해도 계속 (continue-on-error)
4. GHCR 패키지 삭제                        ← 실패해도 계속
5. K8s 매니페스트 삭제
6. git push → ArgoCD prune
```

> **부분 setup 복구**: tunnel API 실패로 manifests가 미생성된 경우
> 1. 앱 레포에서: `git commit --allow-empty -m "retry setup" && git push`
> 2. 또는 GitHub Actions에서 해당 workflow "Re-run all jobs"
> 3. 앱 레포 CI의 check job이 `deployment.yaml` 미존재 감지 (GitHub API로 확인, 이미 구현됨)
>    → `already-setup: false` → setup job 재실행 → tunnel API 재시도

> **커밋 메시지**: tunnel 성공 시 `feat: add APP (subdomain.domain)`,
> 실패 시 `feat: add DNS for APP — tunnel 실패, manifests 미생성`

> **앱 제거 순서**: teardown 먼저 → 레포 삭제 나중
> 레포를 먼저 삭제해도 teardown은 정상 동작하지만, teardown을 아예 안 하면 모든 리소스가 영구 잔존.

---

## 시나리오별 위험도

| 시나리오 | 위험도 | 잔존 리소스 | 대응 |
|---|---|---|---|
| 정상 (teardown → 레포 삭제) | 낮음 | 없음 (finalizer가 NS도 정리) | - |
| 레포 먼저 삭제 → teardown | 낮음 | teardown 정상 동작 | - |
| teardown 안 함 | **높음** | **전체 잔존** | 주간 감사 workflow가 감지 → Telegram 알림 |
| Tunnel API만 실패 | 낮음 | tunnel rule 잔존 (DNS 없어 영향 없음) | 주간 감사에서 drift 감지 |
| Terraform만 실패 | 낮음 | 변경 push 안 됨 | 재실행으로 복구 |

---

## Concurrency 설계

setup-app은 앱 레포 CI의 setup job에서 실행되며, 이미 concurrency가 있음:
```yaml
concurrency:
  group: homelab-terraform
  cancel-in-progress: false
```

Tunnel API도 같은 job 내에서 순차 실행됨.

> **교차 레포 제약**: `homelab-terraform` concurrency group은 레포 단위로 격리.
> 서로 다른 앱 레포의 setup과 homelab의 teardown은 동시 실행 가능.
> 같은 앱의 setup과 teardown이 동시에 트리거되면 GET→PUT race 발생 가능.
> homelab 규모에서는 현실적으로 발생하지 않으나, 동일 앱의 setup/teardown 동시 실행 금지.

---

## API Token 권한

기존 Org Secret 재사용, 추가 권한 불필요:
- `Account: Cloudflare Tunnel → Edit` — **이미 있음** ✅

> 시크릿 이름이 `TF_` prefix (TF_CLOUDFLARE_TOKEN, TF_ACCOUNT_ID, TF_TUNNEL_ID)이지만,
> 기존 Org Secrets를 재사용하기 위함이며 Terraform 전용이 아님.

---

## 테스트 계획

### E2E 테스트
```
생성:
  1. template-web에서 test-blog 재생성 (subdomain=blog 설정 후 첫 push)
  2. CI 전체 파이프라인 성공 확인
  3. blog.ukkiee.dev 접속 확인
  4. tunnel ingress 확인: manage-tunnel-ingress.sh list
  5. GHCR 패키지 존재 확인: gh api orgs/.../packages/container/test-blog

부분 setup 복구:
  6. 환경변수에 잘못된 CF_TOKEN 설정
  7. setup 실행 → tunnel 실패 → apps.json/DNS만 push 확인
  8. deployment.yaml 미존재 확인 (manifests 미생성)
  9. 올바른 CF_TOKEN으로 앱 레포 CI 재실행
 10. tunnel 성공 → manifests 생성 → 완전 setup 확인

제거:
 11. teardown dispatch
 12. DNS CNAME 삭제 확인: dig blog.ukkiee.dev
 13. tunnel ingress 제거 확인: manage-tunnel-ingress.sh list
 14. K8s namespace 삭제 확인 (finalizer): kubectl get ns test-blog
 15. GHCR 패키지 삭제 확인
 16. 앱 레포 삭제
```

### 엣지 케이스 테스트
| 테스트 | 예상 결과 |
|---|---|
| 이미 존재하는 hostname add (동일 service) | 스킵 + exit 0 |
| hostname 동일 + service 다른 add | 교체 + exit 0 |
| 존재하지 않는 hostname remove | 스킵 + exit 0 |
| 잘못된 토큰으로 실행 | HTTP 에러 + exit 1 |
| API 타임아웃 | 30초 후 exit 1 |
| catch-all만 남은 상태에서 add | 정상 추가 |
| 여러 hostname 순차 add | 기존 rule 유지 |
| DRY_RUN=true | config 출력만, PUT 없음 |
| list 액션 | 현재 hostname 목록 출력 |
| 부분 setup → 재시도 (잘못된 CF_TOKEN) | tunnel 실패 → apps.json만 push → 올바른 토큰으로 재실행 → 완전 setup |

---

## 부속 개선 A: ArgoCD Application finalizer (NS 자동 삭제)

setup-app이 생성하는 ArgoCD Application에 finalizer를 추가하면,
Application 삭제 시 하위 K8s 리소스 + Namespace까지 cascade delete.

```yaml
metadata:
  name: $APP
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io    # ← 추가 (background 방식)
```

**변경 파일**: `.github/actions/setup-app/action.yml`의 ArgoCD Application heredoc
**기존 앱 적용**: `argocd/applications/apps/*.yaml` 7개 파일에 수동 추가

> **Background vs Foreground finalizer**:
> - `resources-finalizer.argocd.argoproj.io` (background): Application 삭제 즉시 완료, 리소스 삭제는 비동기
> - `resources-finalizer.argocd.argoproj.io/foreground`: 모든 리소스 삭제 완료까지 대기
> homelab 규모에서 즉시 재생성할 일이 드물므로 background로 충분.

> **infra 앱에는 finalizer를 넣지 않음**:
> cloudflared, traefik, argocd 등 infra 앱에 finalizer를 넣으면
> 실수로 Application 삭제 시 클러스터 핵심 인프라가 cascade 삭제됨.
> apps 디렉토리 앱에만 적용.

---

## 부속 개선 B: 고아 앱 + Tunnel drift 주간 감사 workflow

teardown 없이 레포가 삭제된 경우를 감지하여 Telegram 알림.

**새 파일**: `.github/workflows/audit-orphans.yml`

### 감사 대상
1. **고아 앱**: `apps.json`에 등록된 앱 중 레포가 존재하지 않는 경우
   - `manifests/apps/*` 전체가 아닌 **apps.json 기반** (false positive 방지)
   - immich, postgresql 등 외부 이미지 앱은 제외 목록으로 스킵
2. **Tunnel drift**: apps.json 엔트리와 tunnel ingress rule이 불일치하는 경우

### 동작
```
매주 월요일 09:00 KST (cron: '0 0 * * 1' UTC)
  ├─ apps.json의 managed 앱 순회 → 레포 존재 확인 (제외 목록 적용)
  ├─ apps.json subdomain vs Tunnel API ingress rule 비교
  │   └─ sed 정규식에서 도메인의 `.`을 이스케이프 처리
  └─ 불일치 발견 시 Telegram 알림
```

### 알림 예시
```
🔍 주간 감사
고아 앱 2개: old-project, deprecated-api
정리: gh workflow run teardown.yml -f app-name=<이름>

⚠️ Tunnel drift:
DNS에만: new-app
Tunnel에만: removed-app
```

### 오탐 방지
- `apps.json` 기반 감사 + 제외 목록으로 외부 이미지 앱(immich 등) 스킵
- 앱 레포가 private이면 API 접근 실패 → 고아로 오탐 (현재 모든 앱 레포 public이므로 해당 없음)
- **규약**: GHCR 패키지 이름은 반드시 앱 이름(레포 이름)과 동일해야 함

> **보안 참고 (별도 이슈)**: setup-app의 기존 step들에 `${{ inputs.* }}`가
> `run:` 블록에 직접 삽입되는 셸 인젝션 벡터가 있음.
> 새 tunnel API step은 env 패턴으로 보호했으나, 기존 step은 이번 범위 밖.
> 후속 보안 패치로 기존 step도 env 패턴으로 통일 필요.

---

## 부속 개선 C: GitHub App 권한 추가

GHCR 패키지 삭제에 `packages:write` 권한 필요:

```
GitHub → Settings → Developer settings → GitHub Apps → ukkiee-deploy-bot
→ Permissions → Repository permissions → Packages → Read and write
→ Save → Org 재승인
```

---

## 앱 완전 제거 절차 (최종)

### 정상 경로
```
1. teardown workflow dispatch (app-name 입력)
   ├─ apps.json 제거
   ├─ Terraform apply (DNS CNAME 삭제)
   ├─ Tunnel API (ingress rule 제거)
   ├─ GHCR 패키지 삭제
   ├─ manifests/ + argocd/ 파일 삭제
   └─ git push → ArgoCD prune + finalizer → K8s 리소스 + NS 삭제
2. 앱 레포 삭제 (GitHub)
3. 끝. 수동 작업 없음.
```

### 비정상 경로 (teardown 안 하고 레포 삭제)
```
1. 주간 감사 workflow가 고아 앱 감지
2. Telegram 알림 수신 (앱 이름 + 대응 방법)
3. teardown workflow 수동 실행
4. 정상 경로와 동일하게 정리
```

---

## 구현 순서

> Phase 간 의존성을 반영한 순서. 특히 GitHub App 권한(부속 C)은
> teardown GHCR 삭제보다 먼저 완료해야 함.

```
0. 부속 C: GitHub App packages:write 권한 추가 (선행 조건)

1. Phase 1: .github/scripts/manage-tunnel-ingress.sh 작성
   └─ 로컬 DRY_RUN=true 테스트

2. Phase 2 + 3 (동시 가능):
   ├─ setup-app 수정 (tunnel API step, Commit & Push, outputs, description, 주석, targetRevision)
   ├─ teardown 수정 (tunnel API step, GHCR 삭제 step)
   ├─ test-blog ci.yml 수정 (id: setup, job-level output, warning step, update-manifest 조건)
   └─ template-web CI 템플릿 동일 수정

3. 부속 A: ArgoCD finalizer
   ├─ setup-app 템플릿에 finalizer 추가
   └─ 기존 앱 7개에 수동 추가 (infra 앱 제외)

4. 테스트:
   ├─ test-blog teardown → 재생성 E2E
   ├─ NS 자동 삭제 확인 (finalizer)
   ├─ tunnel ingress 추가/제거 확인 (list)
   ├─ GHCR 패키지 삭제 확인
   └─ 엣지 케이스 테스트

5. 부속 B: 감사 workflow (독립, 아무 때나)
   └─ .github/workflows/audit-orphans.yml 작성
```
