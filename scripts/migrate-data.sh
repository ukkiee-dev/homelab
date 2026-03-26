#!/bin/bash
set -euo pipefail

# =============================================================================
# 데이터 마이그레이션 헬퍼
# 로컬 디렉토리 데이터를 K8s PVC로 복사
#
# 사전 조건:
#   - 대상 StatefulSet이 이미 생성되어 있을 것 (kubectl apply)
#   - 소스 데이터 디렉토리가 존재할 것
#
# PVC 네이밍 규칙: <volumeClaimTemplate-name>-<statefulset-name>-<ordinal>
#   예: data-uptime-kuma-0, conf-adguard-0
#
# 사용법: ./scripts/migrate-data.sh <service>
# =============================================================================

SERVICE="${1:?서비스 이름을 지정하세요 (uptime-kuma|adguard|traefik|portainer)}"

# -----------------------------------------------------------------------------
# copy_to_pvc: 임시 pod을 생성하여 PVC에 데이터를 복사
#
# 인자:
#   $1 - namespace
#   $2 - PVC 이름
#   $3 - 소스 로컬 디렉토리
#   $4 - PVC 내 마운트 경로 (기본값: /data)
# -----------------------------------------------------------------------------
copy_to_pvc() {
    local namespace="$1"
    local pvc_name="$2"
    local source_dir="$3"
    local dest_path="${4:-/data}"
    local pod_name="migrate-${SERVICE}-$(echo "${pvc_name}" | head -c 10)"

    echo "==> PVC '${pvc_name}'에 데이터 복사 중 (${source_dir} → ${dest_path})"
    echo "    namespace: ${namespace}"

    # 임시 busybox pod 생성하여 PVC 마운트
    kubectl run "${pod_name}" \
        --namespace="${namespace}" \
        --image=busybox:1.36 \
        --restart=Never \
        --overrides="{
            \"spec\": {
                \"containers\": [{
                    \"name\": \"migrate\",
                    \"image\": \"busybox:1.36\",
                    \"command\": [\"sleep\", \"3600\"],
                    \"volumeMounts\": [{
                        \"name\": \"data\",
                        \"mountPath\": \"${dest_path}\"
                    }]
                }],
                \"volumes\": [{
                    \"name\": \"data\",
                    \"persistentVolumeClaim\": {
                        \"claimName\": \"${pvc_name}\"
                    }
                }]
            }
        }"

    # pod이 Ready 상태가 될 때까지 대기
    echo "==> 임시 pod 대기 중..."
    kubectl wait --for=condition=Ready "pod/${pod_name}" \
        --namespace="${namespace}" --timeout=60s

    # kubectl cp로 데이터 복사
    echo "==> 데이터 복사 중..."
    kubectl cp "${source_dir}/." "${namespace}/${pod_name}:${dest_path}"

    # 정리: 임시 pod 삭제
    echo "==> 임시 pod 삭제"
    kubectl delete pod "${pod_name}" --namespace="${namespace}" --grace-period=0

    echo "==> 완료: ${pvc_name}"
}

# -----------------------------------------------------------------------------
# 서비스별 마이그레이션 로직
# -----------------------------------------------------------------------------
case "${SERVICE}" in
    uptime-kuma)
        copy_to_pvc "apps" "data-uptime-kuma-0" "./uptime-kuma/data" "/app/data"
        ;;
    adguard)
        # AdGuard는 conf와 work 두 개의 PVC 사용
        copy_to_pvc "apps" "conf-adguard-0" "./adguard/conf" "/opt/adguardhome/conf"
        copy_to_pvc "apps" "work-adguard-0" "./adguard/work" "/opt/adguardhome/work"
        ;;
    traefik)
        copy_to_pvc "traefik-system" "traefik-letsencrypt" "./traefik/letsencrypt" "/letsencrypt"
        ;;
    portainer)
        copy_to_pvc "apps" "data-portainer-0" "./portainer/data" "/data"
        ;;
    *)
        echo "지원 서비스: uptime-kuma, adguard, traefik, portainer"
        exit 1
        ;;
esac
