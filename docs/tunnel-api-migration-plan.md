# Cloudflare Tunnel Ingress 자동화 — API 직접 호출 방식

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
2. **catch-all 보존** — `http_status:404`는 항상 마지막
3. **중복 방지** — 추가 전 동일 hostname 제거 후 삽입
4. **멱등성** — 이미 있으면 스킵, 없으면 스킵

---

## 구현 계획

### Phase 1: 스크립트 작성

**`.github/scripts/manage-tunnel-ingress.sh`**:

```bash
#!/bin/bash
set -euo pipefail

ACTION="$1"         # add | remove
ACCOUNT_ID="$2"
TUNNEL_ID="$3"
CF_TOKEN="$4"
HOSTNAME="$5"
SERVICE="${6:-http://traefik:80}"

API_URL="https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations"

# 1. 현재 config 조회
echo "📡 현재 tunnel config 조회..."
RESPONSE=$(curl -sf -H "Authorization: Bearer $CF_TOKEN" "$API_URL")
CONFIG=$(echo "$RESPONSE" | jq '.result.config')

# 현재 ingress에서 catch-all 분리
RULES=$(echo "$CONFIG" | jq '[.ingress[] | select(.service != "http_status:404")]')
CATCHALL='{"service": "http_status:404"}'

case "$ACTION" in
  add)
    # 중복 제거 후 추가
    EXISTING=$(echo "$RULES" | jq --arg h "$HOSTNAME" '[.[] | select(.hostname == $h)] | length')
    if [ "$EXISTING" -gt 0 ]; then
      echo "⏭️  $HOSTNAME 이미 존재, 스킵"
      exit 0
    fi
    NEW_RULE="{\"hostname\": \"$HOSTNAME\", \"service\": \"$SERVICE\"}"
    UPDATED=$(echo "$RULES" | jq --argjson rule "$NEW_RULE" '. + [$rule]')
    echo "✅ $HOSTNAME 추가"
    ;;
  remove)
    UPDATED=$(echo "$RULES" | jq --arg h "$HOSTNAME" '[.[] | select(.hostname != $h)]')
    echo "✅ $HOSTNAME 제거"
    ;;
  *)
    echo "❌ Unknown action: $ACTION (add|remove)"
    exit 1
    ;;
esac

# catch-all 재추가 + PUT
FINAL_CONFIG=$(echo "$CONFIG" | jq --argjson rules "$UPDATED" --argjson catchall "$CATCHALL" \
  '.ingress = ($rules + [$catchall])')

# 2. config 업데이트
echo "📡 tunnel config 업데이트..."
RESULT=$(curl -sf -X PUT "$API_URL" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"config\": $FINAL_CONFIG}")

if echo "$RESULT" | jq -e '.success' > /dev/null; then
  echo "✅ tunnel config 업데이트 완료"
else
  echo "❌ 업데이트 실패: $RESULT"
  exit 1
fi
```

### Phase 2: setup-app action 수정

**변경 위치**: terraform apply 이후, manifests 생성 이전

```yaml
    # ── Step 2.5: Tunnel Ingress 추가 (API 직접 호출) ────────────
    - name: Add tunnel ingress
      if: ${{ inputs.type != 'worker' }}
      shell: bash
      env:
        CF_TOKEN: ${{ inputs.tf-cloudflare-token }}
        ACCOUNT_ID: ${{ inputs.tf-account-id }}
        TUNNEL_ID: ${{ inputs.tf-tunnel-id }}
        SUBDOMAIN: ${{ inputs.subdomain }}
        DOMAIN: ${{ inputs.domain }}
      run: |
        bash _homelab/.github/scripts/manage-tunnel-ingress.sh \
          add "$ACCOUNT_ID" "$TUNNEL_ID" "$CF_TOKEN" \
          "${SUBDOMAIN}.${DOMAIN}" "http://traefik:80"
```

### Phase 3: teardown workflow 수정

**변경 위치**: terraform apply 이후, manifests 제거 이전

```yaml
    # ── Step 2.5: Tunnel Ingress 제거 (API 직접 호출) ────────────
    - name: Remove tunnel ingress
      if: steps.remove.outputs.in_apps_json == 'true'
      env:
        CF_TOKEN: ${{ secrets.TF_CLOUDFLARE_TOKEN }}
        ACCOUNT_ID: ${{ secrets.TF_ACCOUNT_ID }}
        TUNNEL_ID: ${{ secrets.TF_TUNNEL_ID }}
        SUBDOMAIN: ${{ steps.remove.outputs.subdomain }}
        DOMAIN: ${{ secrets.TF_DOMAIN }}
      run: |
        bash .github/scripts/manage-tunnel-ingress.sh \
          remove "$ACCOUNT_ID" "$TUNNEL_ID" "$CF_TOKEN" \
          "${SUBDOMAIN}.${DOMAIN}" "http://traefik:80"
```

---

## 실행 순서 (최종)

### 앱 생성 (setup)
```
1. apps.json 업데이트
2. Terraform apply (DNS CNAME 생성)
3. Tunnel Ingress API (hostname 추가)     ← 신규
4. K8s 매니페스트 생성
5. ArgoCD Application 생성
6. git push
```

### 앱 제거 (teardown)
```
1. apps.json에서 제거
2. Terraform apply (DNS CNAME 삭제)
3. Tunnel Ingress API (hostname 제거)     ← 신규
4. K8s 매니페스트 삭제
5. git push
```

---

## 안전성 비교

| 항목 | Terraform (이전) | API 직접 호출 (신규) |
|---|---|---|
| 전체 교체 위험 | **있음** (replace 방식) | **없음** (GET→수정→PUT) |
| State 충돌 | **있음** (tfstate vs 대시보드) | **없음** (API가 source of truth) |
| 기존 rule 영향 | **있음** (전체 덮어쓰기) | **없음** (해당 hostname만 수정) |
| 멱등성 | terraform이 보장 | 스크립트에서 중복 체크 |
| 속도 | ~2분 (init+plan+apply) | ~5초 (curl 2회) |
| 장애 시 복구 | state cleanup 필요 | 재실행으로 복구 |

---

## Cloudflare API Token 권한

기존 토큰에 추가 권한 필요 없음:
- `Account: Cloudflare Tunnel → Edit` — **이미 있음** ✅
- tunnel configurations 읽기/쓰기 가능

---

## 구현 순서

```
1. .github/scripts/manage-tunnel-ingress.sh 작성
2. .github/actions/setup-app/action.yml 수정 (tunnel API step 추가)
3. .github/workflows/teardown.yml 수정 (tunnel API step 추가)
4. 로컬 테스트 (스크립트 단독 실행)
5. test-blog teardown → 재생성 E2E 테스트
```

---

## 주의사항

1. **API 호출 실패 시**: DNS/K8s는 정상 진행, tunnel만 수동 추가 필요 (non-blocking)
2. **동시 실행**: 두 앱이 동시에 setup하면 GET→PUT 사이 race condition 가능. 하지만 homelab 규모에서는 현실적으로 발생하지 않음
3. **catch-all 보존**: 스크립트가 항상 `http_status:404`를 마지막에 유지
4. **대시보드 호환**: API로 수정한 내용은 대시보드에 즉시 반영됨
