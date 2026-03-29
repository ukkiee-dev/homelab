#!/bin/bash
set -euo pipefail

# Homelab SealedSecret 관리 스크립트
#
# 사용법:
#   ./scripts/seal-secret.sh list                              - 전체 시크릿/키 목록 조회
#   ./scripts/seal-secret.sh list <namespace>                  - 특정 네임스페이스만 조회
#   ./scripts/seal-secret.sh set <namespace> <secret> <key>    - 키 추가/수정 (값을 프롬프트로 입력)
#   ./scripts/seal-secret.sh set <ns> <secret> <key> <value>   - 키 추가/수정 (값 직접 전달)
#
# 예시:
#   ./scripts/seal-secret.sh list
#   ./scripts/seal-secret.sh list monitoring
#   ./scripts/seal-secret.sh set monitoring monitoring-secrets GRAFANA_ADMIN_PASSWORD
#   ./scripts/seal-secret.sh set monitoring monitoring-secrets GRAFANA_ADMIN_PASSWORD 'newpass123'

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# SealedSecret YAML 파일 경로 찾기
find_sealed_secret_file() {
    local name="$1"
    local namespace="$2"
    local found
    found=$(grep -rl "name: ${name}" "${REPO_ROOT}/manifests/" --include="*sealed-secret*.yaml" 2>/dev/null | while read -r f; do
        if grep -q "namespace: ${namespace}" "$f" 2>/dev/null; then
            echo "$f"
        fi
    done | head -1)
    echo "$found"
}

cmd_list() {
    local filter_ns="${1:-}"

    echo "=== SealedSecret 목록 ==="
    echo ""

    local format='NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].type,SYNCED:.status.conditions[0].status'

    if [[ -n "$filter_ns" ]]; then
        kubectl get sealedsecrets -n "$filter_ns" -o custom-columns="$format" 2>/dev/null || {
            echo "네임스페이스 '$filter_ns'에 SealedSecret이 없습니다."
            return
        }
    else
        kubectl get sealedsecrets -A -o custom-columns="$format" 2>/dev/null
    fi

    echo ""
    echo "=== 키 상세 ==="
    echo ""

    local namespaces
    if [[ -n "$filter_ns" ]]; then
        namespaces="$filter_ns"
    else
        namespaces=$(kubectl get sealedsecrets -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u)
    fi

    for ns in $namespaces; do
        local secrets
        secrets=$(kubectl get sealedsecrets -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
        for secret in $secrets; do
            local keys
            keys=$(kubectl get sealedsecret "$secret" -n "$ns" -o jsonpath='{range .spec.encryptedData}{@}{"\n"}{end}' 2>/dev/null \
                | sed 's/:.*//' | tr -d '{}' )
            # 더 정확한 키 목록 추출
            keys=$(kubectl get sealedsecret "$secret" -n "$ns" -o json 2>/dev/null \
                | python3 -c "import sys,json; d=json.load(sys.stdin).get('spec',{}).get('encryptedData',{}); [print(k) for k in sorted(d.keys())]" 2>/dev/null)

            local file
            file=$(find_sealed_secret_file "$secret" "$ns")
            local file_info=""
            if [[ -n "$file" ]]; then
                file_info=" (${file#$REPO_ROOT/})"
            fi

            echo "[$ns/$secret]${file_info}"
            for key in $keys; do
                echo "  - $key"
            done
            echo ""
        done
    done
}

cmd_set() {
    local namespace="$1"
    local secret="$2"
    local key="$3"
    local value="${4:-}"

    # 값이 없으면 프롬프트로 입력받기
    if [[ -z "$value" ]]; then
        echo -n "값 입력 (${namespace}/${secret} → ${key}): "
        read -rs value
        echo ""
        if [[ -z "$value" ]]; then
            echo "ERROR: 값이 비어있습니다."
            exit 1
        fi
    fi

    # SealedSecret 파일 찾기
    local target_file
    target_file=$(find_sealed_secret_file "$secret" "$namespace")

    if [[ -z "$target_file" ]]; then
        echo "ERROR: '${namespace}/${secret}'에 대한 SealedSecret YAML을 찾을 수 없습니다."
        echo ""
        echo "새로 생성하려면 먼저 manifests/ 아래에 sealed-secret.yaml 파일을 만들어주세요."
        exit 1
    fi

    echo "대상 파일: ${target_file#$REPO_ROOT/}"
    echo "시크릿:    ${namespace}/${secret}"
    echo "키:        ${key}"
    echo ""

    # kubeseal로 암호화 후 merge
    echo -n "$value" \
        | kubectl create secret generic "$secret" \
            --namespace="$namespace" \
            --dry-run=client \
            --from-file="${key}=/dev/stdin" \
            -o yaml \
        | kubeseal --controller-name=sealed-secrets --controller-namespace=kube-system --format yaml --merge-into "$target_file"

    echo "SealedSecret 업데이트 완료: ${target_file#$REPO_ROOT/}"
    echo ""
    echo -n "Git에 커밋하고 push할까요? (y/n): "
    read -r answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        git -C "$REPO_ROOT" add "$target_file"
        git -C "$REPO_ROOT" commit -m "feat: update ${key} in ${secret}"
        git -C "$REPO_ROOT" push
        echo "반영 완료!"

        # Grafana 비밀번호 변경 시 DB에도 반영
        if [[ "$secret" == "monitoring-secrets" && "$key" == "GRAFANA_ADMIN_PASSWORD" ]]; then
            echo ""
            echo "Grafana DB에 비밀번호를 동기화합니다..."
            # ArgoCD sync 대기 후 파드 내 비밀번호 리셋
            echo "ArgoCD sync 대기 중..."
            sleep 30
            NEW_PW=$(kubectl get secret monitoring-secrets -n monitoring -o jsonpath='{.data.GRAFANA_ADMIN_PASSWORD}' | base64 -d)
            kubectl exec -n monitoring deploy/grafana -- grafana cli admin reset-admin-password "$NEW_PW" 2>&1 | tail -1
        fi
    else
        echo "수동으로 반영하려면:"
        echo "  git add ${target_file#$REPO_ROOT/}"
        echo "  git commit && git push"
    fi
}

case "${1:-}" in
    list)
        cmd_list "${2:-}"
        ;;
    set)
        if [[ $# -lt 4 ]]; then
            echo "사용법: $0 set <namespace> <secret-name> <key> [value]"
            echo ""
            echo "예시:"
            echo "  $0 set monitoring monitoring-secrets GRAFANA_ADMIN_PASSWORD"
            echo "  $0 set monitoring monitoring-secrets GRAFANA_ADMIN_PASSWORD 'newpass'"
            exit 1
        fi
        cmd_set "$2" "$3" "$4" "${5:-}"
        ;;
    *)
        echo "Homelab SealedSecret 관리"
        echo ""
        echo "사용법:"
        echo "  $0 list [namespace]                         시크릿/키 목록 조회"
        echo "  $0 set <namespace> <secret> <key> [value]   키 추가/수정"
        echo ""
        echo "예시:"
        echo "  $0 list                                     전체 목록"
        echo "  $0 list monitoring                          monitoring만"
        echo "  $0 set monitoring monitoring-secrets GRAFANA_ADMIN_PASSWORD"
        exit 1
        ;;
esac
