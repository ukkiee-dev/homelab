#!/bin/bash
set -euo pipefail

# Homelab 설정 스크립트 (Mac Mini M4 + OrbStack K8s)
#
# OrbStack K8s는 자체 K3s 클러스터를 제공하므로
# 별도 k3d/k3s 설치가 불필요합니다.
#
# 사용법:
#   ./scripts/setup.sh tools     - CLI 도구 설치
#   ./scripts/setup.sh context   - OrbStack K8s 컨텍스트 전환
#   ./scripts/setup.sh verify    - 클러스터 연결 확인

install_cli_tools() {
    echo "==> CLI 도구 설치 (macOS)"

    # 이미 설치된 도구는 건너뜀
    local tools=(kubectl helm kustomize kubeseal argocd k9s)
    local to_install=()

    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            to_install+=("$tool")
        else
            echo "  [OK] ${tool} ($(command -v "$tool"))"
        fi
    done

    if [ ${#to_install[@]} -eq 0 ]; then
        echo "==> 모든 도구가 이미 설치되어 있습니다."
    else
        echo "==> 설치할 도구: ${to_install[*]}"
        brew install "${to_install[@]}"
    fi

    echo "==> CLI 도구 설치 완료"
}

switch_context() {
    echo "==> OrbStack K8s 컨텍스트 전환"

    if kubectl config get-contexts orbstack &>/dev/null; then
        kubectl config use-context orbstack
        echo "==> 컨텍스트: orbstack"
    else
        echo "ERROR: orbstack 컨텍스트를 찾을 수 없습니다."
        echo "OrbStack에서 Kubernetes를 활성화했는지 확인하세요."
        echo ""
        echo "사용 가능한 컨텍스트:"
        kubectl config get-contexts -o name
        exit 1
    fi
}

verify_cluster() {
    echo "==> 클러스터 연결 확인"
    echo ""

    echo "--- 현재 컨텍스트 ---"
    kubectl config current-context
    echo ""

    echo "--- 노드 상태 ---"
    kubectl get nodes -o wide
    echo ""

    echo "--- 네임스페이스 ---"
    kubectl get namespaces
    echo ""

    echo "==> 클러스터 연결 정상"
}

case "${1:-}" in
    tools)   install_cli_tools ;;
    context) switch_context ;;
    verify)  verify_cluster ;;
    *)
        echo "사용법: $0 {tools|context|verify}"
        echo ""
        echo "  tools   - macOS CLI 도구 설치 (kubectl, helm, k9s 등)"
        echo "  context - OrbStack K8s 컨텍스트로 전환"
        echo "  verify  - 클러스터 연결 상태 확인"
        exit 1
        ;;
esac
