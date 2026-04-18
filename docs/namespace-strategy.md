# 네임스페이스 전략

> 최종 업데이트: 2026-04-18

## 분류 기준

| 기준 | 전용 NS | 공유 NS (apps) |
|------|---------|---------------|
| CI/CD 자동 생성 앱 | test-web 등 (setup-app 생성) | - |
| 경량 stateful/stateless | - | adguard, homepage, uptime-kuma, postgresql |

## 현재 네임스페이스 맵

| NS | 용도 | 워크로드 | 관리 방식 |
|----|------|---------|----------|
| **apps** | 사용자 앱 (공유) | adguard, homepage, uptime-kuma, postgresql | ArgoCD Kustomize + Helm(pg) |
| **test-web** | CI/CD 테스트 앱 (격리) | test-web | ArgoCD Kustomize (자동 생성) |
| **monitoring** | 모니터링 스택 | victoria-metrics, grafana, alloy, node-exporter, ksm, vlogs | ArgoCD Kustomize |
| **argocd** | GitOps 엔진 | controller, server, repo-server, redis, image-updater | Helm + ArgoCD Kustomize |
| **traefik-system** | 리버스 프록시 | traefik | ArgoCD Helm multi-source |
| **tailscale-system** | VPN 오퍼레이터 | operator, ts-adguard-proxy | ArgoCD Helm multi-source |
| **networking** | 터널 | cloudflared | ArgoCD Kustomize |
| **kube-system** | K3s 시스템 | coredns, metrics-server, reloader, local-path, svclb | K3s 관리 + Helm(reloader) |
| **actions-runner-system** | CI/CD 러너 | arc-controller, runner-set | Helm |

## 격리 기준

**전용 NS 사용 조건** (하나 이상 해당):
1. 독자적 DB + PVC가 있고 다른 앱과 공유하지 않음
2. CI/CD 파이프라인이 자동으로 생성/삭제 (test-web 등)
3. 클러스터 인프라 구성요소 (traefik, tailscale, argocd, monitoring)

**apps 공유 NS** 조건:
- 경량 앱으로 PVC가 작거나 없음
- 다른 앱과 리소스 충돌 위험이 낮음
- 별도 격리 요구사항이 없음

## ResourceQuota 영향

apps NS에 4개 앱이 공유하므로, 하나의 앱이 과다 사용하면 다른 앱이 영향받음.
현재 quota: requests 540Mi, limits 970Mi — 4개 앱 합산 관리.

## 향후 고려사항

- adguard를 전용 NS로 분리 검토 (DNS 서비스로 격리 가치 있음)
- postgresql을 전용 NS로 분리 검토 (DB 보안 격리)
- 분리 시 PVC rebind, NetworkPolicy 재작성, ResourceQuota 재조정 필요
