# 코드 리뷰 잔여 작업

> 작성: 2026-04-02 | 기반: `_workspace/05_integrated_report.md`
> 완료: 19/22건 | 잔여: 3건 (대규모 아키텍처 변경)

---

## 1. Helm release → ArgoCD multi-source Application 전환 (C-4 + W-5)

ArgoCD 자체, ARC runners, PostgreSQL의 3개 Helm release가 ArgoCD Application으로 관리되지 않음.
traefik/tailscale-operator처럼 multi-source 패턴으로 통일해야 함.

### 대상

| Helm Release | NS | 현재 관리 | 목표 |
|---|---|---|---|
| argocd | argocd | `helm upgrade` 직접 실행 | ArgoCD multi-source Application |
| arc-runner-set | actions-runner-system | `helm upgrade` 직접 실행 | ArgoCD multi-source Application |
| postgresql | apps | `helm upgrade` 직접 실행 | ArgoCD multi-source Application |

### 위험

- Helm release ownership 이전 시 기존 리소스의 `meta.helm.sh/release-*` 어노테이션 충돌
- 마이그레이션 중 ArgoCD가 리소스를 삭제 후 재생성할 수 있음 (PVC 데이터 손실 위험)
- ArgoCD 자체를 ArgoCD로 관리하는 self-management 순환 의존성

### 접근 방법

1. postgresql (가장 안전) → arc-runners → argocd (가장 위험) 순서로 진행
2. 각 전환 전 `helm get values` 저장 + PVC 백업 확인
3. `helm uninstall --keep-history` 후 ArgoCD Application 생성
4. 또는 Helm adopt 패턴: ArgoCD Application에 `Replace=true` ServerSideApply 사용

---

## 2. 네임스페이스 전략 문서화 (W-1) — ✅ 완료

---

## 참고: 완료 항목 요약

| # | 항목 | 완료일 |
|---|------|--------|
| C-1 | ArgoCD API IngressRoute tailscale-only | 2026-04-02 |
| C-2 | Alloy securityContext 강화 | 2026-04-02 |
| C-3 | Grafana Chat ID 환경변수화 | 2026-04-02 |
| C-5 | immich-ml limit 768Mi | 2026-04-02 |
| C-6 | postgresql-backup 고정 태그 | 2026-04-02 |
| C-7 | AppProject 권한 분리 | 2026-04-02 |
| W-2 | 보안 헤더 SSOT (Traefik 일원화) | 2026-04-02 |
| W-3~4 | scheduling/network-policies namespace | 2026-04-02 |
| W-6~9 | monitoring NP, securityContext, CI permissions | 2026-04-02 |
| W-10~13 | ARC 리소스, CPU quota, metric filter, prune 분리 | 2026-04-02 |
| W-14~15 | 레이블 수정, git push retry DRY | 2026-04-02 |
| + | ArgoCD controller/repo-server limit 상향 (OOM 대응) | 2026-04-02 |
| + | ArgoCD ResourceQuota 1400Mi 조정 | 2026-04-02 |
