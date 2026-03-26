# Phase 1 구현 체크리스트 — Prometheus + Grafana + Loki + AlertManager

> 시작일: 2026-03-26
> 플랜 문서: `docs/implementation-plan.md`

---

## Phase 1-A: kube-prometheus-stack ✅

- [x] `monitoring` namespace 생성
- [x] Helm values.yaml 작성 (K3s 호환, PVC, Grafana admin Secret)
- [x] Grafana admin Secret 생성 (Bitwarden 저장 필요)
- [x] Telegram bot token Secret 생성
- [x] kube-prometheus-stack Helm 배포 (v72.6.2)
- [x] Pod 6개 전부 Running
- [x] IngressRoute 생성 (`grafana.ukkiee.dev`, web + websecure, tailscale-only)
- [x] Cloudflare Tunnel Public Hostname 추가
- [x] Grafana 접속 확인 (login 리다이렉트 확인)
- [ ] ArgoCD Application 추가 (Helm 기반이라 별도 처리 필요)

## Phase 1-B: AlertManager + Telegram ✅

- [x] Telegram Bot 생성 + Chat ID 확인
- [x] AlertManager config에 Telegram receiver 설정 (bot_token_file)
- [x] 기본 알림 규칙 활성화 (kube-prometheus-stack 기본 포함)
- [x] Immich AlertManager 규칙 추가 (ImmichStorageHigh, ImmichCrashLoop)
- [x] 테스트 알림 Telegram 수신 확인
- [x] Telegram Bot Token Bitwarden 저장 필요

## Phase 1-C: Loki + Promtail ✅

- [x] Loki 배포 (SingleBinary, PVC 10Gi, 30일 보존, v3.6.7)
- [x] Promtail DaemonSet 배포 (v3.5.1)
- [x] Grafana에 Loki 데이터소스 자동 추가 (values.yaml additionalDataSources)
- [x] Loki 로그 수집 확인 (namespace, pod, container 라벨 존재)

## Phase 1-D: 기타 ✅

- [x] Traefik metrics 활성화 + Helm upgrade 적용
- [x] Traefik PodMonitor 생성
- [x] Cloudflared PodMonitor 생성
- [x] monitoring namespace NetworkPolicy 8개 배포
- [x] `backup.sh`에 Monitoring 상태 확인 추가
- [x] Grafana 접속 확인
- [x] Bitwarden에 Grafana + Telegram Bot Token 저장 (Homelab 폴더)

---

## 생성/수정 파일 목록

| 파일 | 용도 |
|------|------|
| `k8s/base/monitoring/` | 모니터링 스택 매니페스트 |
| `argocd/applications/monitoring.yaml` | ArgoCD Application |
| `k8s/overlays/production/kustomization.yaml` | monitoring 추가 |
