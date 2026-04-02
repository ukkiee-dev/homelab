# 코드 리뷰 잔여 작업

> 최종 업데이트: 2026-04-02 | 완료: 20/22건 | 잔여: 2건

---

## 1. Helm release → ArgoCD multi-source Application 전환 (C-4 + W-5) — 보류

### 현재 상태: Helm 직접 관리 유지

| Helm Release | NS | 관리 방식 | 비고 |
|---|---|---|---|
| argocd | argocd | `helm upgrade -f values.yaml` | self-management 위험으로 **전환 제외** |
| postgresql | apps | `helm upgrade` + Kustomize(backup) | multi-source 시도 실패 후 **원복** |
| argocd-image-updater | argocd | `helm upgrade --reuse-values` | argocd와 함께 유지 |
| reloader | kube-system | `helm upgrade` | 경량, 전환 불필요 |

### 2026-04-02 전환 시도 실패 기록

**PostgreSQL multi-source 전환 시도 → 실패 → 원복**

| 단계 | 결과 |
|------|------|
| values.yaml 커스텀 오버라이드 축소 (667줄→20줄) | ✅ 성공 (유지) |
| ArgoCD Application multi-source YAML 작성 | ✅ 작성 |
| `helm uninstall --keep-history` (PVC 보존) | ✅ PVC 안전 |
| OCI repoURL (`oci://registry-1.docker.io/bitnamicharts`) | ❌ Docker Hub tags API 403 Forbidden |
| HTTPS repoURL (`https://charts.bitnami.com/bitnami`) | ❌ repo-server OOM + 캐시 stale |
| repo-server/controller 재시작 | ❌ GPG 키 생성 + 이전 IP 캐시로 connection refused |
| **결과**: PostgreSQL 약 10분 다운타임 발생 | ❌ |
| `helm install` 로 복구 | ✅ 정상 복구 |

### 실패 원인 분석

1. **Docker Hub OCI 인증**: ArgoCD가 anonymous로 tags API 호출 → 403 Forbidden. Docker Hub rate limiting 또는 인증 필요.
2. **HTTPS Bitnami repo**: 리다이렉트(`charts.bitnami.com` → `repo.broadcom.com`) 경유. repo-server가 26MB index.yaml을 다운받다 OOM 가능성.
3. **repo-server 불안정**: limit 192Mi에서 Helm chart render + GPG 키 생성으로 OOM 반복.
4. **ArgoCD 캐시**: repo-server 재시작 후에도 이전 IP/에러가 캐시되어 connection refused 지속.

### 재시도 시 사전 조건

1. repo-server limit **최소 384Mi** 이상으로 상향
2. Docker Hub 인증 설정 (ArgoCD repository credentials)
3. 또는 GitHub Container Registry에 Helm chart를 mirror하여 OCI 인증 문제 회피
4. 전환 시 **Helm release를 uninstall하지 않고** ArgoCD가 ServerSideApply로 adopt하는 방식 시도
5. 다운타임 최소화를 위해 **새 Application을 먼저 sync한 후** Helm release 삭제

### 결론

현재 환경(12Gi RAM, 단일 노드)에서는 **Helm 직접 관리가 더 안전하고 실용적**이다.
helm upgrade는 분기 1~2회 수준이라 자동화 이점이 제한적이고,
multi-source 전환의 위험(다운타임, OOM, 인증)이 이점을 초과한다.

---

## 완료 항목 (20건)

| # | 항목 | 완료일 |
|---|------|--------|
| C-1 | ArgoCD API IngressRoute tailscale-only | 2026-04-02 |
| C-2 | Alloy securityContext 강화 | 2026-04-02 |
| C-3 | Grafana Chat ID (하드코딩 유지, provisioning 제한) | 2026-04-02 |
| C-5 | immich-ml limit 768Mi (이후 immich 전체 폐기) | 2026-04-02 |
| C-6 | postgresql-backup latest 태그 (Helm release와 일치 유지) | 2026-04-02 |
| C-7 | AppProject 권한 분리 (apps, monitoring) | 2026-04-02 |
| W-1 | 네임스페이스 전략 문서화 | 2026-04-02 |
| W-2 | 보안 헤더 SSOT (Traefik 일원화, Cloudflare Transform 제거) | 2026-04-02 |
| W-3 | scheduling App destination namespace | 2026-04-02 |
| W-4 | network-policies App destination namespace | 2026-04-02 |
| W-6 | monitoring NS NetworkPolicy 추가 | 2026-04-02 |
| W-7 | 백업 CronJob securityContext | 2026-04-02 |
| W-8 | Grafana 컨테이너 securityContext | 2026-04-02 |
| W-9 | CI/CD 워크플로우 permissions | 2026-04-02 |
| W-10 | ARC runner 리소스 축소 + PriorityClass | 2026-04-02 |
| W-11 | actions-runner-system ResourceQuota | 2026-04-02 |
| W-12 | kubernetes-nodes scrape metric_relabel | 2026-04-02 |
| W-13 | Restic prune 주간 분리 | 2026-04-02 |
| W-14 | ArgoCD Application component 레이블 | 2026-04-02 |
| W-15 | git push retry composite action | 2026-04-02 |
| + | ArgoCD controller 768Mi, repo-server 192Mi 상향 | 2026-04-02 |
| + | ArgoCD ResourceQuota 1400Mi | 2026-04-02 |
| + | immich 전체 폐기 | 2026-04-02 |
