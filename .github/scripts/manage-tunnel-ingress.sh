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
echo "현재 tunnel config 조회..."
HTTP_CODE=$(curl -s -o "$TMPFILE" -w '%{http_code}' "${CURL_OPTS[@]}" \
  -H "Authorization: Bearer $CF_TOKEN" "$API_URL") || {
  echo "API 연결 실패"; exit 1
}
BODY=$(cat "$TMPFILE")

if [ "$HTTP_CODE" != "200" ]; then
  echo "API 응답 HTTP $HTTP_CODE: $BODY"; exit 1
fi

CONFIG=$(echo "$BODY" | jq -e '.result.config') || {
  echo "config 파싱 실패: $BODY"; exit 1
}

RULE_COUNT=$(echo "$CONFIG" | jq '.ingress | length')
if [ "$RULE_COUNT" -lt 1 ]; then
  echo "ingress가 비어있음 — 비정상 상태"; exit 1
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
  echo "마지막 ingress rule에 hostname이 있음 — catch-all 누락"
  echo "현재 config: $(echo "$CONFIG" | jq -c '.ingress')"
  exit 1
fi

BEFORE_COUNT=$(echo "$RULES" | jq 'length')

case "$ACTION" in
  add)
    EXISTING_SERVICE=$(echo "$RULES" | jq -r --arg h "$HOSTNAME" \
      '[.[] | select(.hostname == $h)][0].service // empty')
    if [ "$EXISTING_SERVICE" = "$SERVICE" ]; then
      echo "$HOSTNAME 이미 동일한 service로 존재, 스킵"
      exit 0
    elif [ -n "$EXISTING_SERVICE" ]; then
      echo "$HOSTNAME service 변경: $EXISTING_SERVICE -> $SERVICE"
      RULES=$(echo "$RULES" | jq --arg h "$HOSTNAME" '[.[] | select(.hostname != $h)]')
    fi
    NEW_RULE=$(jq -n --arg h "$HOSTNAME" --arg s "$SERVICE" '{hostname: $h, service: $s}')
    UPDATED=$(echo "$RULES" | jq --argjson rule "$NEW_RULE" '. + [$rule]')
    ;;
  remove)
    EXISTING=$(echo "$RULES" | jq --arg h "$HOSTNAME" '[.[] | select(.hostname == $h)] | length')
    if [ "$EXISTING" -eq 0 ]; then
      echo "$HOSTNAME 없음, 스킵"
      exit 0
    fi
    UPDATED=$(echo "$RULES" | jq --arg h "$HOSTNAME" '[.[] | select(.hostname != $h)]')
    ;;
  *)
    echo "Unknown action: $ACTION (add|remove|list)"; exit 1
    ;;
esac

AFTER_COUNT=$(echo "$UPDATED" | jq 'length')
echo "ingress rules: $BEFORE_COUNT -> $AFTER_COUNT"

# catch-all 재추가 + 최종 config 조립
FINAL_CONFIG=$(echo "$CONFIG" | jq --argjson rules "$UPDATED" --argjson catchall "$CATCHALL" \
  '.ingress = ($rules + [$catchall])')

# dry-run
if [ "${DRY_RUN:-false}" = "true" ]; then
  echo "[DRY-RUN] 변경될 config:"
  echo "$FINAL_CONFIG" | jq .
  exit 0
fi

# 2. config 업데이트 — payload를 jq로 안전하게 조립 (셸 문자열 보간 미사용)
echo "tunnel config 업데이트..."
PAYLOAD=$(jq -n --argjson config "$FINAL_CONFIG" '{config: $config}')

PUT_CODE=$(curl -s -o "$TMPFILE_PUT" -w '%{http_code}' "${CURL_OPTS[@]}" \
  -X PUT "$API_URL" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD") || {
  echo "PUT 요청 실패"; exit 1
}
PUT_BODY=$(cat "$TMPFILE_PUT")

if [ "$PUT_CODE" = "200" ] && echo "$PUT_BODY" | jq -e '.success' > /dev/null; then
  if [ -n "${EXISTING_SERVICE:-}" ] && [ "$EXISTING_SERVICE" != "$SERVICE" ]; then
    echo "update 완료: $HOSTNAME ($EXISTING_SERVICE -> $SERVICE)"
  else
    echo "$ACTION 완료: $HOSTNAME"
  fi
else
  echo "업데이트 실패 (HTTP $PUT_CODE): $PUT_BODY"; exit 1
fi
