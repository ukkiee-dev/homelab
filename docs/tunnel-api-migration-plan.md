# Cloudflare Tunnel Ingress 자동화 — API 직접 호출 방식 v2

## 버전 이력

### v1 → v2 (리뷰 반영)

| # | 문제 | 심각도 | 수정 |
|---|---|---|---|
| 1.1 | 토큰이 CLI 인자($4)로 노출 — ps/proc에서 평문 유출 | P0 | 환경변수로만 전달, 위치 인자에서 제거 |
| 1.2 | curl GET 실패 시 빈 config으로 PUT → 기존 rule 전체 삭제 위험 | P0 | HTTP 상태 검증 + config 파싱 검증 + rule 개수 검증 |
| 1.3 | remove 시 존재하지 않는 hostname에도 PUT 실행 | P1 | 존재 여부 확인 후 없으면 스킵 |
| 3.5 | curl 타임아웃 없음 — API 무응답 시 job 6시간 대기 | P1 | `--connect-timeout 10 --max-time 30` 추가 |
| 2.3 | tunnel API 실패 시 non-blocking → DNS만 있고 tunnel 없는 상태 방치 | P1 | setup에서는 실패 시 중단, teardown에서만 non-blocking |
| 2.1 | GET→PUT race condition (동시 실행 시 변경 유실) | P2 | concurrency group `tunnel-ingress-config` 적용 |
| 2.2 | `_homelab/` prefix 경로 차이 미설명 | P2 | 주석으로 경로 차이 이유 명시 |
| 4.3 | 실패 시 롤백 흐름 미문서화 | P2 | 실패 시 흐름 명시 |
| 4.1 | 멱등성 원칙 불명확 | P2 | add/remove 각각 명시 |
| 3.1-3.4 | dry-run, list, diff, 테스트 계획 | P3 | 추가 |

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

## API 동작 방식

### Endpoint
```
GET/PUT https://api.cloudflare.com/client/v4/accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations
```

### Config 구조
```json
{
  "config": {
    "ingress": [
      { "hostname": "photos.ukkiee.dev", "service": "http://traefik:80" },
      { "hostname": "blog.ukkiee.dev", "service": "http://traefik:80" },
      { "service": "http_status:404" }
    ]
  }
}
```

### 핵심 원칙
1. **GET 먼저** — 현재 config를 읽고 수정 (blind PUT 금지)
2. **GET 응답 검증** — HTTP 200 + config 파싱 + rule 개수 1개 이상 확인
3. **catch-all 보존** — `http_status:404`는 항상 마지막
4. **중복 방지** — 추가 전 동일 hostname 존재하면 스킵
5. **멱등성** — add: 이미 있으면 스킵 (exit 0). remove: 없으면 스킵 (exit 0)
6. **토큰 보호** — CLI 인자가 아닌 환경변수로만 전달

---

## 구현 계획

### Phase 1: 스크립트 작성

**`.github/scripts/manage-tunnel-ingress.sh`**:

> 민감 정보(CF_TOKEN, ACCOUNT_ID, TUNNEL_ID)는 **환경변수로만 전달**.
> 위치 인자에 토큰을 넣으면 `ps aux`/`/proc/*/cmdline`에서 평문 노출됨.

```bash
#!/bin/bash
set -euo pipefail

# 환경변수 필수 확인 (토큰/ID는 CLI 인자로 전달하지 않음)
: "${CF_TOKEN:?CF_TOKEN 환경변수 필요}"
: "${ACCOUNT_ID:?ACCOUNT_ID 환경변수 필요}"
: "${TUNNEL_ID:?TUNNEL_ID 환경변수 필요}"

ACTION="${1:?Usage: manage-tunnel-ingress.sh <add|remove|list> <hostname> [service]}"
HOSTNAME="${2:-}"
SERVICE="${3:-http://traefik:80}"

CURL_OPTS="--connect-timeout 10 --max-time 30"
API_URL="https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations"

# 1. 현재 config 조회 + 검증
echo "📡 현재 tunnel config 조회..."
HTTP_RESPONSE=$(curl -s -w '\n%{http_code}' $CURL_OPTS \
  -H "Authorization: Bearer $CF_TOKEN" "$API_URL") || {
  echo "❌ API 연결 실패"; exit 1
}

HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -1)
BODY=$(echo "$HTTP_RESPONSE" | sed '$d')

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

# list 액션은 조회만
if [ "$ACTION" = "list" ]; then
  echo "$CONFIG" | jq -r '.ingress[] | select(.hostname) | .hostname'
  exit 0
fi

# hostname 필수 확인 (add/remove)
: "${HOSTNAME:?hostname 인자 필요}"

# 현재 ingress에서 catch-all 분리
RULES=$(echo "$CONFIG" | jq '[.ingress[] | select(.service != "http_status:404")]')
CATCHALL='{"service": "http_status:404"}'

BEFORE_COUNT=$(echo "$RULES" | jq 'length')

case "$ACTION" in
  add)
    EXISTING=$(echo "$RULES" | jq --arg h "$HOSTNAME" '[.[] | select(.hostname == $h)] | length')
    if [ "$EXISTING" -gt 0 ]; then
      echo "⏭️  $HOSTNAME 이미 존재, 스킵"
      exit 0
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

# catch-all 재추가
FINAL_CONFIG=$(echo "$CONFIG" | jq --argjson rules "$UPDATED" --argjson catchall "$CATCHALL" \
  '.ingress = ($rules + [$catchall])')

# dry-run 모드
if [ "${DRY_RUN:-false}" = "true" ]; then
  echo "🔍 [DRY-RUN] 변경될 config:"
  echo "$FINAL_CONFIG" | jq .
  exit 0
fi

# 2. config 업데이트
echo "📡 tunnel config 업데이트..."
PUT_RESPONSE=$(curl -s -w '\n%{http_code}' $CURL_OPTS -X PUT "$API_URL" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"config\": $FINAL_CONFIG}") || {
  echo "❌ PUT 요청 실패"; exit 1
}

PUT_CODE=$(echo "$PUT_RESPONSE" | tail -1)
PUT_BODY=$(echo "$PUT_RESPONSE" | sed '$d')

if [ "$PUT_CODE" = "200" ] && echo "$PUT_BODY" | jq -e '.success' > /dev/null; then
  echo "✅ $ACTION 완료: $HOSTNAME"
else
  echo "❌ 업데이트 실패 (HTTP $PUT_CODE): $PUT_BODY"; exit 1
fi
```

### Phase 2: setup-app action 수정

**변경 위치**: terraform apply 이후, manifests 생성 이전

> 경로 `_homelab/`: setup-app은 앱 레포의 CI에서 호출되며,
> homelab을 `_homelab/` 경로에 checkout함. teardown은 homelab 자체 workflow이므로 prefix 없음.

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
      run: |
        bash _homelab/.github/scripts/manage-tunnel-ingress.sh \
          add "${{ inputs.subdomain }}.${{ inputs.domain }}"
```

### Phase 3: teardown workflow 수정

**변경 위치**: terraform apply 이후, manifests 제거 이전

```yaml
    # ── Step 2.5: Tunnel Ingress 제거 (API 직접 호출) ────────────
    # teardown에서는 실패해도 계속 진행 (이미 삭제 중이므로)
    - name: Remove tunnel ingress
      if: steps.remove.outputs.in_apps_json == 'true'
      continue-on-error: true
      env:
        CF_TOKEN: ${{ secrets.TF_CLOUDFLARE_TOKEN }}
        ACCOUNT_ID: ${{ secrets.TF_ACCOUNT_ID }}
        TUNNEL_ID: ${{ secrets.TF_TUNNEL_ID }}
      run: |
        SUBDOMAIN="${{ steps.remove.outputs.subdomain }}"
        DOMAIN="${{ secrets.TF_DOMAIN }}"
        bash .github/scripts/manage-tunnel-ingress.sh \
          remove "${SUBDOMAIN}.${DOMAIN}"
```

---

## 실행 순서 (최종)

### 앱 생성 (setup)
```
1. apps.json 업데이트
2. Terraform apply (DNS CNAME 생성)
3. Tunnel Ingress API (hostname 추가)     ← 신규, 실패 시 workflow 중단
   └─ 실패 시: DNS는 다음 teardown에서 정리
4. K8s 매니페스트 생성
5. ArgoCD Application 생성
6. git push
```

### 앱 제거 (teardown)
```
1. apps.json에서 제거
2. Terraform apply (DNS CNAME 삭제)
3. Tunnel Ingress API (hostname 제거)     ← 신규, 실패해도 계속 진행
4. K8s 매니페스트 삭제
5. git push
```

---

## 안전성 비교

| 항목 | Terraform (이전) | API 직접 호출 v2 |
|---|---|---|
| 전체 교체 위험 | **있음** (replace 방식) | **없음** (GET→수정→PUT) |
| State 충돌 | **있음** (tfstate vs 대시보드) | **없음** (API가 source of truth) |
| 기존 rule 영향 | **있음** (전체 덮어쓰기) | **없음** (해당 hostname만 수정) |
| 빈 config PUT 방지 | 없음 | **있음** (rule 개수 검증) |
| 토큰 보호 | tfstate에 평문 | **환경변수만** (CLI 인자 미사용) |
| 멱등성 | terraform이 보장 | **add/remove 모두 스킵 처리** |
| 타임아웃 | terraform 자체 관리 | **curl 30초** |
| Race condition | terraform lock (R2 미지원) | **concurrency group** |
| 속도 | ~2분 (init+plan+apply) | **~5초** (curl 2회) |
| 장애 시 복구 | state cleanup 필요 | **재실행으로 복구** |

---

## Concurrency 설계

setup-app은 composite action이므로, 호출하는 ci.yml의 setup job에 이미 concurrency가 있음:
```yaml
concurrency:
  group: homelab-terraform
  cancel-in-progress: false
```

Tunnel API도 이 그룹 안에서 실행되므로 **별도 concurrency 불필요** — 같은 job 내에서 순차 실행됨.

teardown도 동일한 `homelab-terraform` concurrency group을 사용하므로, setup과 teardown이 동시에 실행되지 않음.

> 단, 다른 앱 레포에서 동시에 setup이 트리거되면 concurrency group이 레포 단위로 격리됨 (기존 알려진 제약). homelab 규모에서는 순차 생성 권장.

---

## Cloudflare API Token 권한

기존 토큰 사용, 추가 권한 불필요:
- `Account: Cloudflare Tunnel → Edit` — **이미 있음** ✅
- tunnel configurations 읽기/쓰기 가능

> 시크릿 이름이 `TF_` prefix를 사용하지만 (TF_CLOUDFLARE_TOKEN, TF_ACCOUNT_ID, TF_TUNNEL_ID),
> 이는 기존 Org Secrets를 그대로 재사용하기 위함이며 Terraform 전용이 아님.

---

## 테스트 계획

### E2E 테스트
```
1. test-blog teardown
2. test-blog 레포 삭제
3. template-web에서 test-blog 재생성 (subdomain=blog)
4. CI 전체 파이프라인 실행
5. blog.ukkiee.dev 접속 확인
```

### 엣지 케이스 테스트
| 테스트 | 예상 결과 |
|---|---|
| 이미 존재하는 hostname add | 스킵 + exit 0 |
| 존재하지 않는 hostname remove | 스킵 + exit 0 |
| 잘못된 토큰으로 실행 | HTTP 에러 + exit 1 |
| catch-all만 남은 상태에서 add | 정상 추가 |
| 여러 hostname 순차 add | 기존 rule 유지 확인 |
| DRY_RUN=true | config 출력만, PUT 없음 |
| list 액션 | 현재 hostname 목록 출력 |

---

## 구현 순서

```
1. .github/scripts/manage-tunnel-ingress.sh 작성
2. .github/actions/setup-app/action.yml 수정 (tunnel API step 추가)
3. .github/workflows/teardown.yml 수정 (tunnel API step 추가)
4. 로컬 테스트 (DRY_RUN=true로 스크립트 검증)
5. test-blog teardown → 재생성 E2E 테스트
6. 엣지 케이스 테스트
```
