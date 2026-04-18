# Grafana 개선 후속 작업 TODO

> 2026-04-18 Grafana 대시보드 개선 세션 마무리 시점 기록.
> **2026-04-18 후속 세션**: P1 3건 + P2 2건 모두 해결. P3(선택적 대시보드)과 Phase 6 품질 정리만 잔여.
> 원본 계획: [`2026-04-18-grafana-dashboard-improvement.md`](./2026-04-18-grafana-dashboard-improvement.md)
> 감사 보고서: [`_workspace/grafana_dashboard_audit.md`](../../_workspace/grafana_dashboard_audit.md)

---

## 완료 요약

9개 Task + 후속 5건 배포 완료. 대시보드 총 14개 (기존 9 + 신규 5).

| 구분 | 배포된 변경 |
|------|------------|
| UID 고정 | 9개 대시보드 전부 (G6 해소) |
| 로그 가시성 | VictoriaLogs Logs Explorer 대시보드 |
| 앱 메트릭 | PostgreSQL Bitnami exporter sidecar |
| 앱 대시보드 | PostgreSQL, Cloudflared Tunnel |
| 인프라 | Traefik metrics + 대시보드, CoreDNS 대시보드 |
| 알람 UX | Alert Overview 대시보드, 10개 rule에 dashboardUid/panelId deep-link |
| **후속: 로그 파싱** | Alloy `loki.process` JSON/logfmt level 추출 스테이지 |
| **후속: Auto-reload** | Kustomize `configMapGenerator` hash suffix 활성화 (근본 해결) |
| **후속: Runbook** | `docs/runbooks/` 신규 + PostgreSQL helm upgrade 절차 |
| **후속: AppProject** | `infra` project에 `IngressClass` 리소스 허용 |
| **후속: Chart drift** | Traefik `targetRevision` 34.5.0 → 39.0.6 (helm 실 release와 정합) |

---

## P1 후속 이슈 (운영 품질) — ✅ 전부 해결 (2026-04-18)

### [x] Alloy 로그 파싱 스테이지 추가 ✅ 2026-04-18 해결

**해결**: `manifests/monitoring/alloy/config.yaml`에 `loki.process "parse_level"` 블록 추가.
- `stage.json` → JSON 구조화 로그의 `level` 필드 추출 (`level_json`)
- `stage.regex` → logfmt 형식의 `level=info` 추출 (`level_logfmt`)
- `stage.template`으로 `{{ or .level_json .level_logfmt | lower }}` coalesce
- `stage.labels`로 VictoriaLogs label 승격

**주의**: Alloy Flow 문법은 Loki의 stages를 `loki.process { stage.* {} }` 블록으로 감싸는 형태. 원 문서에 기재된 "`stage.logfmt` 파이프라인 추가"는 Grafana Agent(Loki promtail) 문법이라 Alloy에 바로 적용되지 않음 — 교정됨.

**검증 필요**: ArgoCD sync 후 `logs-explorer.json` 패널 3(레벨별 로그 건수)에서 `error`/`warn`/`info` 시리즈 분리 표시 여부.

### [x] Grafana provisioning auto-reload 근본 해결 ✅ 2026-04-18 해결

**근본 원인 재분석**: `dashboard-provider.yaml`의 `updateIntervalSeconds: 30`은 문제가 아니었음. 진짜 원인은 **dashboards 각 카테고리의 `kustomization.yaml`에 `disableNameSuffixHash: true`가 설정되어 있었던 것**. 이 때문에 ConfigMap 내용이 바뀌어도 이름이 동일해 Kubernetes가 Pod volume을 갱신하지 않음.

**해결**: 5개 `dashboards/*/kustomization.yaml` 전부에서 `disableNameSuffixHash: true` 제거.
- `manifests/monitoring/grafana/dashboards/apps/kustomization.yaml`
- `manifests/monitoring/grafana/dashboards/infra/kustomization.yaml`
- `manifests/monitoring/grafana/dashboards/kubernetes/kustomization.yaml`
- `manifests/monitoring/grafana/dashboards/node/kustomization.yaml`
- `manifests/monitoring/grafana/dashboards/workload/kustomization.yaml`

**작동 원리**: 제거 후 Kustomize가 ConfigMap 이름 뒤에 content hash suffix(`-abc123def`)를 붙이고, `nameReference` transformer가 Deployment volumes의 참조도 자동으로 hashed name으로 업데이트. 파일 변경 → 새 ConfigMap 생성 → Deployment Pod rollout → 새 provisioning config 로드. 완전 자동화.

**검증**: `kubectl kustomize manifests/monitoring/grafana/` 출력에서 5개 dashboards ConfigMap이 hash suffix 포함한 이름으로 Deployment volumes에 연결됨 확인 완료.

**이점 vs. 원 대안**:
- 원 옵션 1 (sidecar): 추가 컴포넌트·복잡도 → 불필요해짐.
- 원 옵션 2 (annotation checksum): 수동 관리 필요 → 불필요해짐.
- 채택 방식은 **Kustomize 네이티브 패턴**이라 의존성 0, 유지비 0.

### [x] PostgreSQL helm upgrade password 가드 Runbook 문서화 ✅ 2026-04-18 해결

**해결**: `docs/runbooks/postgresql-helm-upgrade.md` 신규 작성 (`docs/runbooks/` 디렉토리 자체 신규 생성).

**Runbook 구성**:
- 증상 / 트리거 매트릭스 (Renovate PR / 수동 upgrade / values 변경)
- 진단 체크리스트 (Secret / helm history / ArgoCD status)
- 해결 옵션 A (ArgoCD 경유 parameters 주입 — 권장)
- 해결 옵션 B (수동 helm upgrade, selfHeal off 전제)
- 검증 단계 (Pod Ready / DB 접속 / Secret 보존 / ArgoCD Healthy)
- Rollback 절차 (`helm rollback` + git revert)
- 배경 / 근본 원인 설명 (chart rendering 단계의 template 실패 메커니즘)

**파급 효과**: 이 패턴(`auth.existingSecret` + helm rendering 단계 비번 주입)은 MySQL, MongoDB 등 다른 Bitnami chart에도 공통. 향후 해당 chart Runbook도 같은 구조로 작성 가능.

---

## P2 후속 이슈 (기술 부채) — ✅ 전부 해결 (2026-04-18)

### [x] Traefik chart version drift 정리 ✅ 2026-04-18 해결

**해결**: `argocd/applications/infra/traefik.yaml`의 `targetRevision`을 `"34.5.0"` → `"39.0.6"`으로 갱신. 실제 helm release 버전과 일치시켜 drift 제거.

**선택 근거**:
- 실제 Pod이 이미 chart 39.0.6 기반으로 정상 기동 중 → values.yaml이 39.x schema와 호환됨이 실증됨.
- values.yaml 점검 결과: `additionalArguments`로 CLI args를 직접 넣고 있어 chart-specific schema 의존이 최소. 34→39 major bump에도 breaking 없음.
- `kubernetesIngress.enabled: false` 상태라 IngressClass 리소스 자동 생성 경로도 사용 안 함 → 현 시점 회피책(`ingressClass.enabled: false`) 유지 가능.

**검증 필요**: ArgoCD가 sync 후 Synced/Healthy 유지. drift 재발 여부는 다음 `helm history traefik -n traefik-system`로 확인.

**후속 아이디어 (별건)**: P2 AppProject IngressClass 허용이 이제 완료됐으니, 나중에 `ingressClass.enabled: true`로 전환해 표준화 가능 (긴급성 낮음).

### [x] ArgoCD AppProject `infra`에 IngressClass 허용 ✅ 2026-04-18 해결

**해결**: `manifests/infra/argocd/appproject-infra.yaml`의 `clusterResourceWhitelist`에 다음 항목 추가:

```yaml
- group: networking.k8s.io
  kind: IngressClass
```

**이점**:
- Traefik Helm이 `ingressClass.enabled: true`로 되돌아가도 sync 실패 없음.
- 미래 추가 IngressController(예: nginx, contour) 도입 시 AppProject 수정 불필요.
- 기존 회피책(`ingressClass.enabled: false`)은 유지하되, 언제든 복구 가능.

---

## P3 스킵된 대시보드 (가치 낮음, 선택적)

### [ ] Uptime Kuma 대시보드 (plan Task 2.2 + 3.2)

- **가치**: 낮음 — Uptime Kuma UI 자체가 상태 페이지 역할
- **비용**: Basic Auth scrape 설정 + SealedSecret 생성
- **재검토 기준**: Kuma로 외부 서비스 다수 모니터링 시 의미 있음

### [ ] AdGuard 대시보드 (plan Task 2.3 + 3.3)

- **가치**: 낮음 — AdGuard UI 자체가 우수
- **비용**: `ebrianne/adguard-exporter` sidecar + admin 비번 SealedSecret
- **블로커**: 사용자가 AdGuard admin 비번 제공 필요
- **재검토 기준**: DNS 쿼리 분석을 PromQL로 알람 거는 요구 생길 시

### [ ] ArgoCD 대시보드 (plan Task 4.2)

- **가치**: 중간 — ArgoCD UI로 충분하나 알람 연동 목적이면 필요
- **비용**: values.yaml에 controller/server/repo `metrics.enabled: true` 추가 (간단)
- **재검토 기준**: Sync 실패 알람 추가 시

### [ ] Alloy self-monitoring 대시보드 (plan Task 4.4)

- **가치**: 낮음 — DaemonSet 기본 메트릭은 기존 pods 대시보드로 충분
- **비용**: scrape annotation 추가 + 3~4패널
- **재검토 기준**: Alloy 파이프라인 복잡해질 경우

---

## P2 품질 정리 (plan Phase 6)

### [ ] refresh/time 프로파일 정규화 (plan Task 6.1)

- **현황**: 대시보드별 refresh(10s~1m), time range(1h~24h) 제각각
- **목표 2개 프로파일**:
  - 실시간 감시용: `refresh: 30s`, `time.from: now-1h` (대다수 앱·인프라)
  - 용량 예측용: `refresh: 1m`, `time.from: now-24h` (PV, node-exporter-full)
  - 스택 자체: `refresh: 30s`, `time.from: now-3h` (VM, VL, kube-state)
- **규모**: jq 일괄 수정 ~30분.

### [ ] cluster-global vs kube-state-metrics 포지셔닝 재정의 (plan Task 6.2)

- **현황**: 두 대시보드가 "클러스터 전반"을 보여주며 일부 패널 중복.
- **목표**:
  - `cluster-global`: 엔트리 대시보드 — 현재 사용량·트래픽·알람 핫스팟
  - `kube-state-metrics`: 리소스 인벤토리 — 객체 수·요청/제한·desired vs actual
  - 상단 row에 상호 링크 배치
- **규모**: ~1시간.

---

## 실행 지침 (다음 세션 시작 시)

**잔여 작업**: P3 선택적 대시보드 4건 + Phase 6 품질 정리 2건만 남음. 모두 ROI 관점에서 재검토 후 착수 여부 결정 권장.

```bash
# 남은 작업은 가치 낮음 — 필요 시 단일 branch로 진행 가능
git checkout -b chore/grafana-phase6 main
```

### 2026-04-18 후속 세션 검증 체크리스트 (ArgoCD sync 후)

1. **Alloy loki.process**: Alloy Pod 정상 재기동 → `logs-explorer.json` 패널 3에서 level별 분리 확인.
2. **Grafana auto-reload**: dashboard JSON 더미 수정 → commit → push → ArgoCD sync → Pod 자동 rollout 확인 (ConfigMap hash suffix 변경).
3. **AppProject IngressClass**: `kubectl get appproject infra -n argocd -o yaml | grep -A1 IngressClass` 로 whitelist 반영 확인.
4. **Traefik drift**: `kubectl -n argocd get application traefik -o jsonpath='{.status.sync.status}'` → `Synced` 유지. `helm history traefik -n traefik-system`에서 새 revision 없음 확인 (values 무변경).
5. **PostgreSQL Runbook**: 다음 Renovate PR(postgresql chart bump) 시 `docs/runbooks/postgresql-helm-upgrade.md` 절차 적용.

각 Task 진행 시 `docs/plans/2026-04-18-grafana-dashboard-improvement.md` 원본 plan의 해당 Task 참조.

---

## 참고 문서

- 원본 계획: `docs/plans/2026-04-18-grafana-dashboard-improvement.md`
- 감사 보고서: `_workspace/grafana_dashboard_audit.md`
- 운영 컨벤션: `.claude/CONVENTIONS.md`
