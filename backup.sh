#!/bin/bash
set -euo pipefail

# =============================================================================
# K8s PVC 데이터 백업 스크립트
# app 단위로 독립 tar.gz 아카이브를 외장 SSD에 기록
#
# 결과 구조:
#   ${BACKUP_DIR}/<app>/<TIMESTAMP>.tar.gz (+ .sha256)
#
# 사용법: ./backup.sh  (또는 make backup)
# =============================================================================

BACKUP_DIR="${BACKUP_DIR:-/Volumes/ukkiee/homelab/backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RETENTION="${RETENTION:-7}"

if [ ! -d "${BACKUP_DIR}" ]; then
    echo "[ERROR] 백업 디렉토리 없음: ${BACKUP_DIR}" >&2
    echo "        외장 SSD 마운트 및 'mkdir -p ${BACKUP_DIR}' 확인 (Full Disk Access 필요)" >&2
    exit 1
fi
if [ ! -w "${BACKUP_DIR}" ]; then
    echo "[ERROR] 백업 디렉토리 쓰기 불가: ${BACKUP_DIR}" >&2
    echo "        sudo diskutil enableOwnership /Volumes/ukkiee 및 chmod 확인" >&2
    exit 1
fi

sha256() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$@"
    else
        shasum -a 256 "$@"
    fi
}

# -----------------------------------------------------------------------------
# backup_pvc: 실행 중인 pod에서 PVC 데이터를 앱별 tar.gz로 저장
#
# 인자:
#   $1 - namespace
#   $2 - pod label (app.kubernetes.io/name 기준)
#   $3 - 컨테이너 내 경로
#   $4 - app 디렉토리명 (아카이브 상위 폴더명)
#
# 산출물: ${BACKUP_DIR}/${local_name}/${TIMESTAMP}.tar.gz
# 회전: 앱 디렉토리 단위로 최근 ${RETENTION}개만 유지
# -----------------------------------------------------------------------------
backup_pvc() {
    local namespace="$1"
    local pod_label="$2"
    local container_path="$3"
    local local_name="$4"

    local pod_name
    pod_name=$(kubectl get pods -n "${namespace}" -l "app.kubernetes.io/name=${pod_label}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || {
        echo "  [SKIP] ${namespace}/${pod_label}: pod not found"
        return 0
    }

    local app_dir="${BACKUP_DIR}/${local_name}"
    local staging="${app_dir}/.staging-${TIMESTAMP}"
    local archive="${app_dir}/${TIMESTAMP}.tar.gz"

    mkdir -p "${staging}"
    echo "  [BACKUP] ${namespace}/${pod_label} (${container_path})"

    if ! kubectl cp "${namespace}/${pod_name}:${container_path}" "${staging}/" 2>/dev/null; then
        echo "  [WARN] ${namespace}/${pod_label}: kubectl cp failed"
        rm -rf "${staging}"
        return 0
    fi

    tar -czf "${archive}" -C "${staging}" .
    rm -rf "${staging}"

    if [ ! -s "${archive}" ]; then
        echo "  [ERROR] ${namespace}/${pod_label}: archive empty" >&2
        rm -f "${archive}"
        return 0
    fi

    (cd "${app_dir}" && sha256 "${TIMESTAMP}.tar.gz" > "${TIMESTAMP}.tar.gz.sha256")

    # 회전: 앱별 최근 N개만 유지
    (cd "${app_dir}" && ls -t *.tar.gz 2>/dev/null | tail -n +$((RETENTION + 1)) | while read -r f; do
        rm -f "$f" "${f}.sha256"
    done)

    local size
    size=$(du -h "${archive}" | cut -f1)
    echo "           → ${archive} (${size})"
}

echo "=== K8s PVC 백업 시작 (${TIMESTAMP}) ==="

backup_pvc "apps" "uptime-kuma" "/app/data" "uptime-kuma"
backup_pvc "apps" "adguard" "/opt/adguardhome/conf" "adguard"

# --- PostgreSQL 백업 CronJob 상태 확인 (덤프 파일은 PVC에 별도 보관) ---
echo ""
echo "=== PostgreSQL 백업 CronJob 상태 ==="
PG_LAST_JOB=$(kubectl get jobs -n apps -l app.kubernetes.io/name=postgresql-backup --sort-by=.metadata.creationTimestamp --no-headers 2>/dev/null | tail -1 | awk '{print $1, $2}')
if [ -n "$PG_LAST_JOB" ]; then
    echo "  [OK] 마지막 백업 Job: $PG_LAST_JOB"
else
    echo "  [INFO] 백업 CronJob 실행 이력 없음"
fi

echo ""
echo "=== 백업 완료 (${TIMESTAMP}) ==="
