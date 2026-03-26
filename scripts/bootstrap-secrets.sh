#!/bin/bash
set -euo pipefail

# K8s 부트스트랩 시크릿 생성 스크립트
# 클러스터 초기 구성 시 필요한 시크릿을 생성합니다.
#
# 부트스트랩 순서:
#   1. traefik (Cloudflare API) → TLS 인증서 발급
#   2. cloudflare-tunnel-token  → 외부 접근 활성화
#   3. traefik-dashboard-auth   → Traefik 대시보드 인증
#   4. portainer                → Portainer 관리자 비밀번호
#   5. adguard                  → AdGuard 인증 정보
#
# 사전 조건:
#   - kubectl이 클러스터에 연결되어 있을 것
#   - kubeseal CLI가 설치되어 있을 것
#   - sealed-secrets 컨트롤러가 배포되어 있을 것
#
# 사용법: ./scripts/bootstrap-secrets.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== K8s 부트스트랩 시크릿 생성 ==="
echo ""
echo "클러스터 초기 구성에 필요한 시크릿을 생성합니다:"
echo "  1. traefik                 (traefik-system)"
echo "  2. cloudflare-tunnel-token (networking)"
echo "  3. traefik-dashboard-auth  (traefik-system)"
echo "  4. portainer               (apps)"
echo "  5. adguard                 (apps)"
echo ""

# --- 1. Cloudflare API Token (Traefik TLS) ---
echo "--- [1/5] Cloudflare API Token (Traefik TLS 인증서 발급용) ---"
read -rsp "Cloudflare API Token: " CF_API_TOKEN
echo ""
"${SCRIPT_DIR}/seal-secret.sh" traefik traefik-system "kv-api-token=${CF_API_TOKEN}"
echo ""

# --- 2. Cloudflare Tunnel Token ---
echo "--- [2/5] Cloudflare Tunnel Token (외부 접근용) ---"
read -rsp "Cloudflare Tunnel Token: " CF_TUNNEL_TOKEN
echo ""
"${SCRIPT_DIR}/seal-secret.sh" cloudflare-tunnel-token networking "tunnel-token=${CF_TUNNEL_TOKEN}"
echo ""

# --- 3. Traefik Dashboard BasicAuth ---
echo "--- [3/5] Traefik Dashboard BasicAuth ---"
echo "  htpasswd 형식으로 입력 (예: admin:\$2y\$05\$...)"
read -rsp "BasicAuth 해시: " TRAEFIK_AUTH
echo ""
"${SCRIPT_DIR}/seal-secret.sh" traefik-dashboard-auth traefik-system "users=${TRAEFIK_AUTH}"
echo ""

# --- 4. Portainer Admin Password ---
echo "--- [4/5] Portainer 관리자 비밀번호 해시 ---"
echo "  bcrypt 해시 형식으로 입력 (예: \$2y\$05\$...)"
read -rsp "Password Hash: " PORTAINER_HASH
echo ""
"${SCRIPT_DIR}/seal-secret.sh" portainer apps "kv-admin-password-hash=${PORTAINER_HASH}"
echo ""

# --- 5. AdGuard Credentials ---
echo "--- [5/5] AdGuard 인증 정보 ---"
read -rp "AdGuard Username: " ADGUARD_USER
read -rsp "AdGuard Password: " ADGUARD_PASS
echo ""
"${SCRIPT_DIR}/seal-secret.sh" adguard apps "adguard-username=${ADGUARD_USER}" "adguard=${ADGUARD_PASS}"
echo ""

echo "=== 완료 ==="
echo ""
echo "다음 단계:"
echo "  1. 생성된 SealedSecret 파일 확인"
echo "     ls -la k8s/base/*/sealedsecret*.yaml"
echo "  2. git add & commit"
echo "  3. ArgoCD sync 또는 kubectl apply -k k8s/overlays/production"
