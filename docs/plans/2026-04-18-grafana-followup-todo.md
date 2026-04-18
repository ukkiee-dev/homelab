# Grafana 개선 후속 작업 TODO

> 2026-04-18 Grafana 대시보드 개선 세션 마무리 시점 기록.
> 원본 계획: [`2026-04-18-grafana-dashboard-improvement.md`](./2026-04-18-grafana-dashboard-improvement.md)
> 감사 보고서: [`_workspace/grafana_dashboard_audit.md`](../../_workspace/grafana_dashboard_audit.md)

---

## 완료 요약

9개 Task 배포 완료. 대시보드 총 14개 (기존 9 + 신규 5).

| 구분 | 배포된 변경 |
|------|------------|
| UID 고정 | 9개 대시보드 전부 (G6 해소) |
| 로그 가시성 | VictoriaLogs Logs Explorer 대시보드 |
| 앱 메트릭 | PostgreSQL Bitnami exporter sidecar |
| 앱 대시보드 | PostgreSQL, Cloudflared Tunnel |
| 인프라 | Traefik metrics + 대시보드, CoreDNS 대시보드 |
| 알람 UX | Alert Overview 대시보드, 10개 rule에 dashboardUid/panelId deep-link |

---

## P1 후속 이슈 (운영 품질)

### [ ] Alloy 로그 파싱 스테이지 추가

- **문제**: `logs-explorer.json` 패널 3(레벨별 로그 건수)이 빈 결과. Alloy가 raw stdout/stderr만 VictoriaLogs로 푸시, `level` 라벨 파싱 안 함.
- **해결**: `manifests/monitoring/alloy/config.yaml`에 `stage.logfmt` 또는 `stage.json` 파이프라인 추가.
  - 앱별 로그 포맷이 달라 multi-stage 또는 per-namespace 라우팅 필요할 수 있음.
  - JSON 로그 앱(예: cloudflared access log)은 `stage.json`, logfmt 앱은 `stage.logfmt`, plain text는 `stage.regex`.
- **검증**: logs-explorer 패널 3에서 `error`/`warn`/`info` 시리즈가 나뉘어 표시.
- **규모**: ~1시간.

### [ ] Grafana provisioning auto-reload 미작동 회피

- **문제**: `dashboard-provider.yaml`의 `updateIntervalSeconds: 30` 설정에도 Grafana가 ConfigMap 파일 변경을 감지하지 못함. 새 대시보드 추가 시 `/api/admin/provisioning/dashboards/reload` 수동 호출 필요.
- **증거**: Task 1.1·3.4·4.3·5.1 모두 manual reload로 해결.
- **해결 옵션**:
  1. kustomize-sidecar 패턴 (kiwigrid/k8s-sidecar) 도입 → ConfigMap 변경 watch + 자동 reload.
  2. Deployment에 annotation checksum 추가해 ConfigMap 변경 시 pod restart.
  3. 현재 수동 reload 패턴 유지 (단순성).
- **규모**: sidecar 도입 시 ~2시간, annotation checksum은 ~30분.

### [ ] PostgreSQL helm upgrade password 가드 Runbook 문서화

- **문제**: Bitnami postgresql chart는 `auth.existingSecret` 설정에도 불구하고 helm upgrade 시 `global.postgresql.auth.password`를 `--set`으로 전달해야 함. 미전달 시 upgrade 실패.
- **현재**: Task 2.1 실행 시 subagent가 수동으로 secret에서 base64 decode → `--set` 전달.
- **해결**: `docs/runbooks/postgresql-helm-upgrade.md` 작성 — 전달 명령, 검증, rollback 포함.
- **규모**: ~30분.

---

## P2 후속 이슈 (기술 부채)

### [ ] Traefik chart version drift 정리

- **문제**: ArgoCD `traefik` app source는 `targetRevision: 34.5.0`인데 실제 helm release 기록은 `39.0.6`. 이전 수동 helm upgrade 시도(failed) 흔적.
- **영향**: 현재 pod은 v3.3 image, 설정은 ArgoCD 관리 하. 실기능엔 지장 없으나 혼란 소지.
- **해결**:
  1. ArgoCD source `targetRevision`을 최신 stable(39.x 또는 최신)로 갱신.
  2. 또는 실제 release 기록을 34.5.0 기준으로 재정렬 (`helm uninstall` + ArgoCD sync로 재설치).
- **규모**: ~2시간 (upgrade-planner 스킬 활용 권장).

### [ ] ArgoCD AppProject `infra`에 IngressClass 허용 (근본 해결)

- **문제**: Task 4.1에서 Traefik Helm이 기본적으로 IngressClass 리소스를 생성하는데 `infra` project의 `clusterResourceWhitelist`가 이를 허용하지 않아 sync 실패.
- **Workaround**: Task 4.1.2에서 `ingressClass.enabled: false`로 회피.
- **근본 해결**: `manifests/infra/argocd/appproject-infra.yaml`(또는 해당 파일)의 `clusterResourceWhitelist`에 `{group: networking.k8s.io, kind: IngressClass}` 추가.
- **이유**: 미래 다른 IngressController 도입 시 재발 방지.
- **규모**: ~10분.

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

```bash
# 후속 이슈별로 feat branch 분리
git worktree add -b feat/<scope> /Users/ukyi/homelab-<scope> main

# 예시
git worktree add -b feat/alloy-log-parsing /Users/ukyi/homelab-alloy main
git worktree add -b feat/traefik-chart-sync /Users/ukyi/homelab-traefik main
```

각 Task 진행 시 `docs/plans/2026-04-18-grafana-dashboard-improvement.md` 원본 plan의 해당 Task 참조.

---

## 참고 문서

- 원본 계획: `docs/plans/2026-04-18-grafana-dashboard-improvement.md`
- 감사 보고서: `_workspace/grafana_dashboard_audit.md`
- 운영 컨벤션: `.claude/CONVENTIONS.md`
