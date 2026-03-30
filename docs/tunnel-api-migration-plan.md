# Cloudflare Tunnel Ingress 자동화 — API 직접 호출 방식 v3

## 버전 이력

### v1 → v2 (1차 리뷰 반영)

| # | 수정 | 심각도 |
|---|---|---|
| 1.1 | 토큰 CLI 인자 노출 → 환경변수로만 전달 | P0 |
| 1.2 | GET 실패 시 빈 config PUT 방지 → 응답 검증 | P0 |
| 1.3 | remove 멱등성 구현 | P1 |
| 3.5 | curl 타임아웃 추가 | P1 |
| 2.3 | setup 실패 시 workflow 중단 | P1 |
| 2.1 | concurrency group 설명 | P2 |

### v2 → v3 (2차 리뷰 반영)

| # | 수정 | 심각도 |
|---|---|---|
| A.1 | PUT payload 문자열 보간 → jq 조립 | P1 |
| B.2 | hostname 셸 인젝션 방지 → env 전달 | P1 |
| A.3 | catch-all 필터: `http_status:404` → hostname 유무 기반 | P2 |
| A.5 | `$CURL_OPTS` 문자열 → 배열 | P2 |
| A.4 | hostname 동일 + service 다른 경우 교체 처리 | P3 |
| A.2 | HTTP 코드 분리: sed → 파일 기반 | P2 |
| D.1-D.2 | setup-app 주석/description 업데이트 | P2 |
| D.4 | teardown에 GHCR 패키지 삭제 step | P2 |
| C.2 | 앱 제거 순서 + 시나리오별 위험도 문서화 | P1 |
| B.1 | 교차 레포 concurrency 제약 명시 | P2 |

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

# 1. 현재 config 조회 + 검증 (HTTP 코드 파일 분리 — 빈 body 엣지 케이스 방지)
echo "📡 현재 tunnel config 조회..."
HTTP_CODE=$(curl -s -o /tmp/tunnel-response.json -w '%{http_code}' "${CURL_OPTS[@]}" \
  -H "Authorization: Bearer $CF_TOKEN" "$API_URL") || {
  echo "❌ API 연결 실패"; exit 1
}
BODY=$(cat /tmp/tunnel-response.json)

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

BEFORE_COUNT=$(echo "$RULES" | jq 'length')

case "$ACTION" in
  add)
    EXISTING_SERVICE=$(echo "$RULES" | jq -r --arg h "$HOSTNAME" \
      '.[] | select(.hostname == $h) | .service // empty')
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

PUT_CODE=$(curl -s -o /tmp/tunnel-put-response.json -w '%{http_code}' "${CURL_OPTS[@]}" \
  -X PUT "$API_URL" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD") || {
  echo "❌ PUT 요청 실패"; exit 1
}
PUT_BODY=$(cat /tmp/tunnel-put-response.json)

if [ "$PUT_CODE" = "200" ] && echo "$PUT_BODY" | jq -e '.success' > /dev/null; then
  echo "✅ $ACTION 완료: $HOSTNAME"
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
    # setup에서는 실패 시 workflow 중단 (DNS만 있고 tunnel 없는 상태 방지)
    - name: Add tunnel ingress
      if: ${{ inputs.type != 'worker' }}
      shell: bash
      env:
        CF_TOKEN: ${{ inputs.tf-cloudflare-token }}
        ACCOUNT_ID: ${{ inputs.tf-account-id }}
        TUNNEL_ID: ${{ inputs.tf-tunnel-id }}
        HOSTNAME: "${{ inputs.subdomain }}.${{ inputs.domain }}"
      run: |
        bash _homelab/.github/scripts/manage-tunnel-ingress.sh add "$HOSTNAME"
```

**setup-app description 업데이트**:
```yaml
description: Terraform(DNS) + Tunnel API + 매니페스트 생성 → git push
```

**오래된 주석 업데이트**:
```yaml
# ── Step 1: apps.json + Terraform DNS (worker는 스킵) ──────────
# Tunnel ingress는 Step 2.5에서 Cloudflare API로 자동 추가
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
        HOSTNAME: "${{ steps.remove.outputs.subdomain }}.${{ secrets.TF_DOMAIN }}"
      run: |
        bash .github/scripts/manage-tunnel-ingress.sh remove "$HOSTNAME"

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
3. Tunnel Ingress API (hostname 추가)     ← 실패 시 workflow 중단
   └─ 실패 시: DNS는 다음 teardown에서 정리
4. K8s 매니페스트 생성
5. ArgoCD Application 생성
6. git push
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

> **앱 제거 순서**: teardown 먼저 → 레포 삭제 나중
> 레포를 먼저 삭제해도 teardown은 정상 동작하지만, teardown을 아예 안 하면 모든 리소스가 영구 잔존.

---

## 시나리오별 위험도

| 시나리오 | 위험도 | 잔존 리소스 | 대응 |
|---|---|---|---|
| 정상 (teardown → 레포 삭제) | 낮음 | NS만 수동 정리 | `kubectl delete ns` |
| 레포 먼저 삭제 → teardown | 낮음 | teardown 정상 동작 | GHCR만 수동 정리 |
| teardown 안 함 | **높음** | **전체 잔존** | 수동 전체 정리 필요 |
| Tunnel API만 실패 | 낮음 | tunnel rule 잔존 (DNS 없어 영향 없음) | list로 정기 감사 |
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
1. test-blog teardown
2. test-blog 레포 + GHCR 패키지 삭제
3. template-web에서 test-blog 재생성 (subdomain=blog 설정 후 첫 push)
4. CI 전체 파이프라인 실행
5. blog.ukkiee.dev 접속 확인
6. teardown 실행 후 DNS/tunnel/K8s 모두 정리 확인
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

---

## 구현 순서

```
1. .github/scripts/manage-tunnel-ingress.sh 작성
2. .github/actions/setup-app/action.yml 수정
   - description 업데이트
   - 주석 업데이트
   - tunnel API step 추가
3. .github/workflows/teardown.yml 수정
   - tunnel API step 추가
   - GHCR 패키지 삭제 step 추가
4. 로컬 테스트 (DRY_RUN=true)
5. test-blog teardown → 재생성 E2E 테스트
6. 엣지 케이스 테스트
```
