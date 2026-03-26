#!/bin/bash
set -euo pipefail

# Sealed Secret 생성 헬퍼
# 사용법: ./scripts/seal-secret.sh <name> <namespace> <key>=<value> [<key>=<value>...]
#
# 부트스트랩 시크릿:
#   ./scripts/seal-secret.sh traefik traefik-system kv-api-token=xxxx
#   ./scripts/seal-secret.sh cloudflare-tunnel-token networking tunnel-token=xxxx
#   ./scripts/seal-secret.sh traefik-dashboard-auth traefik-system users='admin:$2y$...'
#   ./scripts/seal-secret.sh portainer apps kv-admin-password-hash=xxxx
#   ./scripts/seal-secret.sh adguard apps adguard-username=xxxx adguard=xxxx
#   ./scripts/seal-secret.sh arc-runner-github-token actions-runner-system github_token=xxxx

NAME="${1:?Secret 이름을 지정하세요}"
NAMESPACE="${2:?네임스페이스를 지정하세요}"
shift 2

if [ $# -eq 0 ]; then
    echo "ERROR: 최소 하나의 key=value를 지정하세요"
    exit 1
fi

LITERAL_ARGS=()
for arg in "$@"; do
    LITERAL_ARGS+=("--from-literal=${arg}")
done

# Secret 이름 → 출력 디렉토리 매핑
case "${NAME}" in
    traefik)                          DIR="traefik";        FILE="sealedsecret-cloudflare.yaml" ;;
    traefik-dashboard-auth)           DIR="traefik";        FILE="sealedsecret-dashboard-auth.yaml" ;;
    cloudflare-tunnel-token)          DIR="cloudflared";    FILE="sealedsecret.yaml" ;;
    portainer)                        DIR="portainer";      FILE="sealedsecret.yaml" ;;
    adguard)                          DIR="adguard";        FILE="sealedsecret.yaml" ;;
    arc-runner-github-token)          DIR="arc-runners";    FILE="sealedsecret.yaml" ;;
    *)
        echo "ERROR: 알 수 없는 Secret 이름: ${NAME}"
        echo ""
        echo "부트스트랩 시크릿:"
        echo "  traefik                 (traefik-system)         - Cloudflare API 토큰"
        echo "  cloudflare-tunnel-token (networking)             - Tunnel 토큰"
        echo "  traefik-dashboard-auth  (traefik-system)         - 대시보드 인증"
        echo "  portainer              (apps)                    - 관리자 비밀번호"
        echo "  adguard                (apps)                    - 인증 정보"
        echo "  arc-runner-github-token (actions-runner-system)  - GitHub PAT"
        exit 1
        ;;
esac

OUTPUT_PATH="k8s/base/${DIR}/${FILE}"

echo "==> Secret '${NAME}' 생성 후 Sealing (namespace: ${NAMESPACE})"
echo "    출력: ${OUTPUT_PATH}"

kubectl create secret generic "${NAME}" \
    --namespace="${NAMESPACE}" \
    --dry-run=client \
    -o yaml \
    "${LITERAL_ARGS[@]}" \
    | kubeseal --format yaml \
    > "${OUTPUT_PATH}"

echo "==> 완료: ${OUTPUT_PATH}"
echo "    git add 후 커밋하세요."
