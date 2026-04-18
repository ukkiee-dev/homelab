#!/bin/bash
set -euo pipefail

# =============================================================================
# K8s PVC 데이터 백업 스크립트
# 각 서비스의 PVC 데이터를 로컬로 백업
#
# 사용법: ./backup.sh
# =============================================================================

BACKUP_DIR="$(cd "$(dirname "$0")" && pwd)/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DEST="${BACKUP_DIR}/${TIMESTAMP}"

mkdir -p "${DEST}"

# -----------------------------------------------------------------------------
# backup_pvc: 실행 중인 pod에서 PVC 데이터를 로컬로 복사
#
# 인자:
#   $1 - namespace
#   $2 - pod label (app.kubernetes.io/name 기준)
#   $3 - 컨테이너 내 경로
#   $4 - 로컬 백업 디렉토리명
# -----------------------------------------------------------------------------
backup_pvc() {
    local namespace="$1"
    local pod_label="$2"
    local container_path="$3"
    local local_name="$4"

    local pod_name
    pod_name=$(kubectl get pods -n "${namespace}" -l "app.kubernetes.io/name=${pod_label}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || {
        echo "  [SKIP] ${pod_label}: pod not found"
        return 0
    }

    echo "  [BACKUP] ${pod_label} (${namespace}/${pod_name}:${container_path})"
    mkdir -p "${DEST}/${local_name}"
    kubectl cp "${namespace}/${pod_name}:${container_path}" "${DEST}/${local_name}/" 2>/dev/null || {
        echo "  [WARN] ${pod_label}: copy failed (pod may not have tar)"
        return 0
    }
}

echo "=== K8s PVC 백업 시작 (${TIMESTAMP}) ==="

backup_pvc "apps" "uptime-kuma" "/app/data" "uptime-kuma"
backup_pvc "apps" "adguard" "/opt/adguardhome/conf" "adguard-conf"
backup_pvc "apps" "adguard" "/opt/adguardhome/work" "adguard-work"
backup_pvc "traefik-system" "traefik" "/letsencrypt" "traefik-acme"

# --- PostgreSQL 백업 CronJob 상태 확인 (덤프 파일은 PVC에 별도 보관) ---
echo ""
echo "=== PostgreSQL 백업 CronJob 상태 ==="
PG_LAST_JOB=$(kubectl get jobs -n apps -l app.kubernetes.io/name=postgresql-backup --sort-by=.metadata.creationTimestamp --no-headers 2>/dev/null | tail -1 | awk '{print $1, $2}')
if [ -n "$PG_LAST_JOB" ]; then
    echo "  [OK] 마지막 백업 Job: $PG_LAST_JOB"
else
    echo "  [INFO] 백업 CronJob 실행 이력 없음"
fi

# --- Monitoring 상태 확인 (TSDB는 자동 재수집 가능, 복원 우선순위 낮음) ---
echo ""
echo "=== Monitoring 상태 확인 ==="
MON_PODS=$(kubectl get pods -n monitoring --no-headers 2>/dev/null | awk '{print $1, $3}')
if [ -n "$MON_PODS" ]; then
    echo "  [OK] Monitoring Pods:"
    echo "$MON_PODS" | while read -r name status; do
        echo "        $name: $status"
    done
else
    echo "  [WARN] Monitoring pods not found"
fi

# 압축
echo "==> 압축 중..."
tar -czf "${DEST}.tar.gz" -C "${BACKUP_DIR}" "${TIMESTAMP}"
rm -rf "${DEST}"

# 무결성 검사
if [ ! -s "${DEST}.tar.gz" ]; then
    echo "[ERROR] 백업 파일이 비어있습니다" >&2
    exit 1
fi

# 체크섬 생성 (macOS/Linux 호환)
if command -v sha256sum &>/dev/null; then
    sha256sum "${DEST}.tar.gz" > "${DEST}.tar.gz.sha256"
else
    shasum -a 256 "${DEST}.tar.gz" > "${DEST}.tar.gz.sha256"
fi

FILE_SIZE=$(du -sh "${DEST}.tar.gz" | cut -f1)
echo "=== 백업 완료: ${DEST}.tar.gz (${FILE_SIZE}) ==="

# 최근 7개 백업만 유지
cd "${BACKUP_DIR}"
ls -t *.tar.gz 2>/dev/null | tail -n +8 | while read -r f; do
    rm -f "$f" "${f}.sha256"
done
