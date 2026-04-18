# Grafana 대시보드 개선 실행 계획

> **For Claude:** 이 계획을 단계별로 실행할 때 `executing-plans` 또는 `subagent-driven-development` 스킬을 사용한다. 각 Task는 독립 커밋을 목표로 작성되었으며, `manifests/` 변경은 git push만으로 ArgoCD가 자동 동기화한다.

**Goal**: 2026-04-18 감사 보고서(`_workspace/grafana_dashboard_audit.md`)에서 식별된 10개 갭(G1~G10, P0 3건 / P1 5건 / P2 2건)을 단계적으로 해소해 단일 K3s 홈랩의 옵저버빌리티를 "인프라 가시성은 있으나 앱 레이어 장애 판별 불가" → "앱·인프라·로그·알람까지 Grafana 단일 창에서 추적 가능"으로 끌어올린다.

**Architecture**: 6개 단계의 점진적 전개 + producer-reviewer 패턴.
1. **Phase 0 Foundation** — UID 고정·scrape annotation 파일럿 (다른 Phase의 선결 조건).
2. **Phase 1 Log Visibility** — VictoriaLogs 로그 검색 대시보드 (독립 실행 가능, 즉시 효용).
3. **Phase 2 App Metrics Enablement** — PostgreSQL/Uptime Kuma/AdGuard exporter/annotation 확산.
4. **Phase 3 App Dashboards** — Phase 2의 메트릭 위에 앱별 대시보드 빌드.
5. **Phase 4 Infra Visibility** — Traefik/ArgoCD/CoreDNS/Cloudflared 구성요소.
6. **Phase 5 Alert UX** — 알람 현황 대시보드 + 대시보드 역링크.
7. **Phase 6 Polish** — 중복 정리, refresh 프로파일 통일.

**Tech Stack**: K3s on OrbStack VM, ArgoCD(GitOps), Helm(bitnami/postgresql, traefik, argo-cd), Kustomize, VictoriaMetrics(scrape), VictoriaLogs(로그), Alloy(로그 수집), Grafana(12.x, unified alerting, provisioning).

**Non-goals**:
- 새 알람 규칙 대량 추가 (기존 9개 규칙은 이번 계획에서 유지)
- Grafana 버전 업그레이드
- VictoriaMetrics → Prometheus 마이그레이션
- 메트릭 보존 기간 변경

---

## 의존성 그래프

```
Phase 0 (UID, scrape 파일럿)
   ├─→ Phase 1 (로그 대시보드, 독립)
   ├─→ Phase 2 (앱 exporter) → Phase 3 (앱 대시보드)
   ├─→ Phase 4 (인프라 대시보드)
   └─→ Phase 5 (알람 UX)
                    └─→ Phase 6 (정리)
```

- Phase 1은 Phase 0과 병렬 실행 가능 (VL 수집은 이미 Alloy가 처리 중).
- Phase 3은 Phase 2의 메트릭 수집이 검증된 **후에만** 진행.
- Phase 6은 최종 단계. 중복 대시보드는 앱 대시보드가 실전 검증된 뒤에 판단.

## 공통 운영 패턴

모든 Task는 다음 4단계를 따른다:

1. **Before 상태 캡처** (PromQL/LogsQL/kubectl): 변경 전 관측값을 기록.
2. **파일 수정** (정확한 경로, 전체 패치).
3. **적용 + 검증**:
   - `git add <paths> && git commit -m "..."`
   - ArgoCD: `kubectl -n argocd get app` OutOfSync 확인 → 자동 Sync 대기 (≤ 3분) 또는 `argocd app sync <app>`.
   - **ArgoCD selfHeal 주의** (CLAUDE 메모리): 반드시 git push 먼저. kubectl patch로 먼저 바꾸면 selfHeal이 원복함.
4. **After 상태 검증**: Before와 비교해 기대 변화가 발생했는지 확인. 실패하면 롤백.

VictoriaMetrics 쿼리 엔드포인트: `http://victoria-metrics.monitoring.svc:8481/select/0/prometheus/api/v1/query` (vmselect) 또는 Grafana Explore.

## Acceptance Criteria (전체 계획 완료 기준)

- [ ] 9개 대시보드 모두 고정 `uid`를 가진다.
- [ ] Grafana Explore에서 `{namespace="apps"} |= "error"` LogsQL이 즉시 결과를 반환한다.
- [ ] PostgreSQL/Uptime Kuma/AdGuard 각각 전용 대시보드가 존재하며 핵심 앱 메트릭(DB 연결·모니터 상태·DNS 쿼리)이 표시된다.
- [ ] Traefik `traefik_service_requests_total`, ArgoCD `argocd_app_info`, Cloudflared `cloudflared_tunnel_ha_connections` 메트릭이 VM에 수집된다.
- [ ] `ALERTS{alertstate="firing"}` 기반 "Alert Overview" 대시보드가 있다.
- [ ] alerting.yaml 9개 rule 중 7개 이상이 `annotations.dashboardUid`를 가진다.
- [ ] `grafana-dashboards.md`에 개선된 대시보드 목록이 반영된다.

## 리스크 & 롤백 전략

| 리스크 | 발생 조건 | 롤백 |
|--------|----------|------|
| scrape 추가로 VM 디스크 급증 | 앱이 메트릭을 수천 개 노출 | `metric_relabel_configs`에 `drop` 추가하거나 annotation 제거 |
| PostgreSQL exporter sidecar 추가 시 PG 재시작 | Helm chart가 STS 재생성 | PDB 없으므로 단발 재시작 허용. 앱 downtime 초 단위 |
| UID 변경으로 기존 북마크 URL 깨짐 | 사용자 브라우저 북마크 | 의도된 변경. 변경 후 README에 새 URL 공지 |
| ArgoCD가 Helm chart의 Service metrics.enabled 충돌 표시 | Helm + ArgoCD ownership (CLAUDE 메모리) | `argocd app sync --force`가 아닌 Application manifest에 `ServerSideApply=true` 설정 |
| cloudflared metrics 포트가 NetworkPolicy로 차단됨 | networking ns default-deny 있을 경우 | NetworkPolicy egress에 monitoring ns 허용 추가 |

---

# Phase 0: Foundation (P0 선결)

## Task 0.1: 9개 대시보드 UID 고정

**갭**: G6 — 모든 대시보드 `uid: null`로 인해 파일 변경 시 링크 붕괴.

**Files (modify)**:
- `manifests/monitoring/grafana/dashboards/kubernetes/cluster-global.json`
- `manifests/monitoring/grafana/dashboards/kubernetes/namespaces.json`
- `manifests/monitoring/grafana/dashboards/kubernetes/nodes.json`
- `manifests/monitoring/grafana/dashboards/kubernetes/pods.json`
- `manifests/monitoring/grafana/dashboards/kubernetes/persistent-volumes.json`
- `manifests/monitoring/grafana/dashboards/node/node-exporter-full.json`
- `manifests/monitoring/grafana/dashboards/workload/kube-state-metrics-v2.json`
- `manifests/monitoring/grafana/dashboards/workload/victoriametrics.json`
- `manifests/monitoring/grafana/dashboards/workload/victorialogs.json`

**UID 매핑**:

| 파일 | 할당 UID |
|------|----------|
| cluster-global | `k8s-cluster-global` |
| namespaces | `k8s-namespaces` |
| nodes | `k8s-nodes` |
| pods | `k8s-pods` |
| persistent-volumes | `k8s-pvc` |
| node-exporter-full | `node-exporter-full` |
| kube-state-metrics-v2 | `kube-state-metrics` |
| victoriametrics | `victoriametrics-single` |
| victorialogs | `victorialogs-single` |

**Step 1 — Before 검증**: 최상단 dashboard uid 필드 상태 확인.

```bash
for f in manifests/monitoring/grafana/dashboards/**/*.json; do
  echo "=== $f ==="
  jq -r '.uid // "null"' "$f"
done
```

기대: 9개 모두 `null`.

**Step 2 — 각 JSON 최상단의 `"uid": null`을 매핑 테이블대로 교체**.

주의: 내부 패널의 `"datasource": {"uid": "grafana"}` 필드는 건드리지 않는다. **최상단 루트 필드의 `uid`만** 변경.

```bash
jq '.uid = "k8s-cluster-global"' manifests/.../cluster-global.json > /tmp/out.json && mv /tmp/out.json manifests/.../cluster-global.json
# 9회 반복
```

**Step 3 — After 검증**:

```bash
for f in manifests/monitoring/grafana/dashboards/**/*.json; do
  printf "%-50s %s\n" "$(basename $f)" "$(jq -r '.uid' $f)"
done
```

기대: 9개 파일 모두 매핑된 UID 출력.

**Step 4 — 커밋 + 배포**:

```bash
git add manifests/monitoring/grafana/dashboards/
git commit -m "feat(grafana): assign stable UIDs to 9 dashboards

Enables stable cross-dashboard links and alert dashboardUid references.
See docs/plans/2026-04-18-grafana-dashboard-improvement.md Task 0.1."
git push
```

**Step 5 — Grafana 적용 검증** (Grafana가 ConfigMap 재읽기까지 최대 30초):

```bash
kubectl -n monitoring get cm grafana-dashboards -o yaml | yq '.data | keys'
kubectl -n monitoring rollout status deploy/grafana
# Grafana UI: https://grafana.<domain>/d/k8s-nodes/... URL 접근 확인
```

**Rollback**: 해당 커밋 revert. UID 제거 시 기존 해시 UID로 복귀.

---

## Task 0.2: cloudflared scrape annotation 파일럿 + 검증

**갭**: G3 — `prometheus.io/scrape: "true"`가 전 매니페스트 0건. cloudflared는 이미 `--metrics 0.0.0.0:2000`으로 노출 중이므로 annotation만 추가하면 즉시 검증 가능.

**Files (modify)**: `manifests/infra/cloudflared/` 내 Deployment YAML (실제 파일명은 실행 시 `ls` 확인).

**Step 1 — Before**: cloudflared 메트릭 수집 여부 확인.

Grafana Explore → VictoriaMetrics:
```promql
cloudflared_tunnel_ha_connections
```
기대: `No data` 또는 빈 결과.

파드 내 메트릭 엔드포인트 생존 확인:
```bash
kubectl -n networking port-forward deploy/cloudflared 2000:2000 &
curl -s http://localhost:2000/metrics | head -20
```
기대: `cloudflared_*` 메트릭 출력.

**Step 2 — Deployment의 `spec.template.metadata.annotations`에 추가**:

```yaml
spec:
  template:
    metadata:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "2000"
        prometheus.io/path: "/metrics"
```

주의: `spec.template.metadata` 아래에 넣어야 Pod에 annotation이 붙고 scrape 대상이 된다. `metadata.annotations`(Deployment 자체)에 넣으면 안 됨.

**Step 3 — 커밋 + Sync 대기**:

```bash
git add manifests/infra/cloudflared/
git commit -m "feat(cloudflared): expose metrics to VictoriaMetrics

Adds prometheus.io/scrape annotations so VM auto-discovery picks up
the /metrics endpoint already exposed by --metrics 0.0.0.0:2000."
git push
```

ArgoCD 동기화 확인:
```bash
kubectl -n argocd get app cloudflared -o jsonpath='{.status.sync.status}'
kubectl -n networking rollout status deploy/cloudflared
```

**Step 4 — After 검증** (파드 재시작 후 90~120초 대기, VM scrape interval 반영):

```bash
# VictoriaMetrics targets API
kubectl -n monitoring port-forward svc/victoria-metrics 8429:8429 &
curl -s http://localhost:8429/api/v1/targets | jq '.data.activeTargets[] | select(.labels.namespace=="networking") | {job, health, scrape_url}'
```
기대: cloudflared 대상이 `health: "up"`.

PromQL:
```promql
cloudflared_tunnel_ha_connections
up{namespace="networking", app="cloudflared"}
```
기대: 값 존재.

**Rollback**: 해당 annotation 3줄 제거 후 커밋. 파일럿이므로 영향 최소.

**학습 목적**: 이 파일럿이 성공하면 Phase 2/4에서 같은 패턴을 uptime-kuma, traefik, argocd, coredns에 적용한다.

---

# Phase 1: 로그 가시성 (P0, 독립 실행)

## Task 1.1: VictoriaLogs 로그 검색 대시보드 신규 생성

**갭**: G1 — VL 데이터소스를 쓰는 패널이 0개. Alloy가 모든 Pod 로그를 이미 수집 중이나 Grafana에서 탐색 UI 없음.

**Files (create)**:
- `manifests/monitoring/grafana/dashboards/workload/logs-explorer.json`
- `manifests/monitoring/grafana/dashboards/workload/kustomization.yaml` (리소스 추가)

**Step 1 — 데이터소스 UID 확인**:

`manifests/monitoring/grafana/datasources.yaml`에서 VictoriaLogs 데이터소스의 `uid` 필드 확인. (없으면 `victorialogs`로 고정 설정 추가가 선행 작업.)

**Step 2 — 대시보드 설계** (최소 7개 패널):

| # | 타입 | 제목 | LogsQL/PromQL |
|---|------|------|-----------|
| 1 | Stat | 전체 로그 인입율(line/s) | `rate(vl_rows_inserted_total[5m])` (VM 데이터소스) |
| 2 | Time series | 네임스페이스별 로그 볼륨 | VL: `* \| stats by(namespace) count() \| sort by(count) desc` |
| 3 | Time series | 레벨별 로그 건수 (ERROR/WARN/INFO) | VL: `*\|keep level=~"(?i)error\|warn\|info"\|stats by(level) count()` |
| 4 | Logs | 실시간 로그 스트림 (변수 필터링) | VL: `{namespace=~"$ns", pod=~"$pod"} \|= "$query"` |
| 5 | Table | Top 10 에러 발생 파드 | VL: `_time:5m (level:error OR msg:error) \| stats by(namespace, pod) count() \| sort by(count) desc \| limit 10` |
| 6 | Time series | 재시작 시각 로그 스냅샷 | 링크 전용: `kube_pod_container_status_last_terminated_reason` 시점 전후 10분 로그 |
| 7 | Logs | Alloy 자체 로그 | VL: `{namespace="monitoring", app="alloy"}` |

**템플릿 변수**:
- `$ns`: `label_values(vl_rows_inserted_total, namespace)` (multi, all)
- `$pod`: `{namespace="$ns"} | stats by(pod) count()` 추출 (Grafana VL 플러그인의 label_values 지원 시)
- `$query`: textbox, 기본값 빈 문자열
- `$level`: custom 값 `error,warn,info,debug`

**UID**: `vl-logs-explorer` (Task 0.1 규약).

**Step 3 — 대시보드 JSON 작성**:

`dashboard-designer` 서브에이전트에 위 7개 패널 명세를 전달해 생성. 결과를 `logs-explorer.json`에 저장.

명령 예시 (subagent-driven-development 패턴):
```
Agent(subagent_type: "dashboard-designer", prompt: """
VictoriaLogs 로그 검색 대시보드를 생성한다. UID: vl-logs-explorer.
패널 7개 명세: [위 표]
데이터소스: victorialogs (VL), victoriametrics (VM).
템플릿 변수: $ns, $pod, $query, $level.
파일 경로: manifests/monitoring/grafana/dashboards/workload/logs-explorer.json.
refresh: 30s, time: 1h.
""")
```

**Step 4 — Kustomization 업데이트**:

`manifests/monitoring/grafana/dashboards/workload/kustomization.yaml`의 `configMapGenerator[0].files`에 `- logs-explorer.json` 추가.

**Step 5 — 커밋**:

```bash
git add manifests/monitoring/grafana/dashboards/workload/
git commit -m "feat(grafana): add VictoriaLogs logs explorer dashboard

Adds 7-panel logs-explorer.json with ns/pod/level drilldowns and
real-time log stream, addressing gap G1 from 2026-04-18 audit."
git push
```

**Step 6 — After 검증**:

1. Grafana UI: `https://grafana.<domain>/d/vl-logs-explorer/logs-explorer` 접근.
2. `$ns=apps`, `$query=error` 필터 적용 → 로그 스트림 패널에 결과 표시.
3. 실제 최근 에러 시각과 패널의 시간 축이 일치하는지 확인.

**Rollback**: 파일 2개 revert.

---

# Phase 2: 앱 메트릭 수집 활성화

## Task 2.1: PostgreSQL metrics exporter 활성화

**갭**: G2 — Bitnami chart의 `metrics.enabled`가 비활성 상태. exporter sidecar가 아예 없음.

**Files (modify)**:
- `manifests/apps/postgresql/values.yaml`

**Step 1 — Before**:

```bash
kubectl -n apps get pods -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].spec.containers[*].name}'
```
기대: `postgresql`만 있고 `metrics` 컨테이너 없음.

PromQL:
```promql
pg_up
```
기대: `No data`.

**Step 2 — `values.yaml`에 metrics 블록 추가**:

```yaml
metrics:
  enabled: true
  resources:
    requests:
      cpu: 10m
      memory: 24Mi
    limits:
      cpu: 100m
      memory: 64Mi
  service:
    annotations:
      prometheus.io/scrape: "true"
      prometheus.io/port: "9187"
  # 기본 exporter 커스텀 쿼리 (WAL, long-running, replication)는 후속 Task에서 추가
```

**주의 (CLAUDE 메모리 - Infisical 교훈)**: Bitnami PG chart는 `metrics.service` 하위 annotation이 Service에만 붙고, sidecar container의 Pod annotation은 자동 전파되지 않을 수 있다. Service를 VM scrape 대상으로 잡으려면 `service-endpoints` job이 수집하므로 service annotation이면 충분하다. 재확인 필요.

**Step 3 — 커밋 + Sync**:

```bash
git add manifests/apps/postgresql/values.yaml
git commit -m "feat(postgresql): enable bitnami metrics exporter sidecar

Exposes pg_up/pg_stat_* metrics for dashboard in Task 3.1.
Resource overhead ~24Mi/10m."
git push
```

```bash
kubectl -n argocd get app postgresql -o jsonpath='{.status.sync.status}'
kubectl -n apps get statefulset postgresql -o jsonpath='{.spec.template.spec.containers[*].name}'
```
기대: `metrics` 컨테이너 추가 확인.

**Step 4 — After**:

```promql
pg_up{namespace="apps"}
pg_stat_database_numbackends
```
기대: 값 존재.

**Rollback**: values.yaml에서 metrics 블록 제거. STS가 재생성되며 sidecar 사라짐.

---

## Task 2.2: Uptime Kuma /metrics scrape annotation

**갭**: G2 — Uptime Kuma 1.18+는 `/metrics` 엔드포인트를 내장 (Basic Auth). annotation 추가 + basic_auth 수집 설정 필요.

**Files (modify)**:
- `manifests/apps/uptime-kuma/statefulset.yaml`
- `manifests/apps/uptime-kuma/service.yaml` (선택)
- `manifests/monitoring/victoria-metrics/scrape-config.yaml` (basic_auth job 추가)

**Step 1 — Before**: 이미지 태그 확인.

```bash
kubectl -n apps get sts uptime-kuma -o jsonpath='{.spec.template.spec.containers[0].image}'
```
기대: `louislam/uptime-kuma:1.23+` 같은 버전. 1.18 미만이면 이 Task 스킵.

`/metrics` 응답 확인:
```bash
kubectl -n apps port-forward sts/uptime-kuma 3001:3001 &
curl -u "admin:<pw>" http://localhost:3001/metrics | head -20
```
기대: `monitor_cert_days_remaining`, `monitor_status` 같은 메트릭.

**Step 2 — Uptime Kuma는 Basic Auth가 필요** — 앱 어노테이션만으로 안 되므로 별도 scrape job을 `scrape-config.yaml`에 추가:

```yaml
- job_name: uptime-kuma
  metrics_path: /metrics
  basic_auth:
    username: admin
    password_file: /etc/vm-secrets/uptime-kuma-password
  kubernetes_sd_configs:
    - role: pod
      namespaces:
        names: [apps]
  relabel_configs:
    - source_labels: [__meta_kubernetes_pod_label_app]
      regex: uptime-kuma
      action: keep
    - source_labels: [__address__]
      regex: (.+):\d+
      replacement: $1:3001
      target_label: __address__
```

SealedSecret으로 `uptime-kuma-password` 시크릿을 `monitoring` ns에 생성하고 VM Deployment에 볼륨 마운트.

**대안 (더 간단)**: Uptime Kuma에서 API Key 기반 Bearer 인증을 지원하면 그 쪽이 경량. 현재 문서상 Basic Auth만 지원이면 위 방식.

**Step 3 — 커밋 + 배포**:

```bash
git add manifests/apps/uptime-kuma/ manifests/monitoring/victoria-metrics/scrape-config.yaml
git commit -m "feat(uptime-kuma): scrape /metrics with basic auth

Adds dedicated scrape job (kubernetes-pods auto-discovery can't do
per-target basic_auth). Password sealed in monitoring ns."
git push
```

**Step 4 — After**:

```promql
up{job="uptime-kuma"}
monitor_status{monitor_name=~".+"}
```
기대: 모니터 목록과 상태(1=up, 0=down) 반환.

**Rollback**: scrape-config에서 uptime-kuma job 삭제 + annotation 제거.

---

## Task 2.3: AdGuard exporter sidecar 도입

**갭**: G2 — AdGuard는 Prometheus 포맷 메트릭이 없음. `ebrianne/adguard-exporter` 같은 외부 exporter가 `/control/status` API를 폴링해 변환한다.

**Files (modify/create)**:
- `manifests/apps/adguard/statefulset.yaml` (sidecar 컨테이너 추가)
- `manifests/apps/adguard/service.yaml` (포트 9617 추가)
- `manifests/apps/adguard/adguard-exporter-secret.sealed.yaml` (신규, AdGuard 인증)

**Step 1 — Before**:

```promql
adguard_num_dns_queries
```
기대: `No data`.

**Step 2 — Exporter 이미지 선택 및 Sidecar 추가**:

권장: `ebrianne/adguard-exporter:latest` (구현이 단순, AdGuard REST API 호출).

statefulset.yaml의 `containers[]`에 추가:

```yaml
- name: exporter
  image: ebrianne/adguard-exporter:1.44
  env:
    - name: ADGUARD_PROTOCOL
      value: http
    - name: ADGUARD_HOSTNAME
      value: localhost
    - name: ADGUARD_PORT
      value: "3000"
    - name: ADGUARD_USERNAME
      valueFrom:
        secretKeyRef:
          name: adguard-exporter-auth
          key: username
    - name: ADGUARD_PASSWORD
      valueFrom:
        secretKeyRef:
          name: adguard-exporter-auth
          key: password
  ports:
    - name: metrics
      containerPort: 9617
  resources:
    requests: { cpu: 10m, memory: 16Mi }
    limits: { cpu: 50m, memory: 48Mi }
```

Pod annotation은 기존 `metadata.annotations` (spec.template.metadata)에 추가:

```yaml
prometheus.io/scrape: "true"
prometheus.io/port: "9617"
prometheus.io/path: "/metrics"
```

**Step 3 — SealedSecret 생성**:

```bash
kubectl create secret generic adguard-exporter-auth \
  --from-literal=username=admin \
  --from-literal=password='<AdGuard UI 비밀번호>' \
  -n apps --dry-run=client -o yaml | kubeseal -o yaml > manifests/apps/adguard/adguard-exporter-secret.sealed.yaml
```

`kustomization.yaml`에 리소스 추가.

**Step 4 — 커밋 + 검증**:

```bash
git add manifests/apps/adguard/
git commit -m "feat(adguard): add prometheus exporter sidecar

ebrianne/adguard-exporter polls AdGuard REST API and exposes
adguard_num_dns_queries/blocked/top_* metrics on :9617."
git push
```

**Step 5 — After**:

```promql
adguard_num_dns_queries
adguard_num_blocked_filtering
```

**Rollback**: sidecar + secret + annotation 제거.

---

# Phase 3: 앱별 대시보드 (Phase 2 메트릭 검증 후)

## Task 3.1: PostgreSQL 대시보드

**Gate**: Task 2.1의 `pg_up{namespace="apps"} == 1` 관측 후 착수.

**Files (create)**:
- `manifests/monitoring/grafana/dashboards/apps/postgresql.json`
- `manifests/monitoring/grafana/dashboards/apps/kustomization.yaml` (신규 폴더)

**UID**: `app-postgresql`.

**핵심 패널 (8개)**:

| # | 패널 | 쿼리 |
|---|------|------|
| 1 | DB Up/Down stat | `pg_up{namespace="apps"}` |
| 2 | 활성 연결 수 | `sum(pg_stat_database_numbackends{datname="api"})` |
| 3 | 연결 고갈 임계 (max_connections 대비 %) | `sum(pg_stat_database_numbackends) / pg_settings_max_connections * 100` |
| 4 | 커밋/롤백 비율 | `rate(pg_stat_database_xact_commit[5m])` vs `rate(pg_stat_database_xact_rollback[5m])` |
| 5 | 슬로 쿼리(>1s) | `pg_stat_activity_max_tx_duration_seconds > 1` |
| 6 | 데이터베이스 크기 | `pg_database_size_bytes{datname="api"}` |
| 7 | WAL 생성량 | `rate(pg_wal_position_bytes[5m])` (가능 시) |
| 8 | 버퍼 히트율 | `rate(pg_stat_database_blks_hit[5m]) / (rate(pg_stat_database_blks_hit[5m]) + rate(pg_stat_database_blks_read[5m]))` |

**Step 1**: `monitoring-ops` 스킬로 dashboard-designer 서브에이전트 호출하여 JSON 생성.

**Step 2**: 새 폴더 `apps/` 추가 → kustomization 업데이트 (`dashboards/kustomization.yaml`에도 `apps` 추가).

**Step 3 — 커밋 + 검증**.

**Acceptance**: 대시보드 접근 시 8패널 모두 실데이터 표시.

---

## Task 3.2: Uptime Kuma 대시보드

**Gate**: Task 2.2의 `monitor_status{...}` 관측 후.

**Files (create)**: `manifests/monitoring/grafana/dashboards/apps/uptime-kuma.json`

**UID**: `app-uptime-kuma`.

**패널 (6개)**:

| # | 패널 | 쿼리 |
|---|------|------|
| 1 | 모니터별 상태 (bar) | `monitor_status` by monitor_name |
| 2 | 현재 Up/Down 카운트 | `sum by (status) (monitor_status)` |
| 3 | 응답시간 추이 | `monitor_response_time_ms` |
| 4 | 24h Uptime % | `avg_over_time(monitor_status[24h]) * 100` |
| 5 | 인증서 만료 임박 | `monitor_cert_days_remaining < 30` |
| 6 | 모니터 실패 이벤트 (테이블) | `changes(monitor_status[1h])` |

---

## Task 3.3: AdGuard 대시보드

**Gate**: Task 2.3의 `adguard_num_dns_queries` 관측 후.

**Files (create)**: `manifests/monitoring/grafana/dashboards/apps/adguard.json`

**UID**: `app-adguard`.

**패널 (6개)**:

| # | 패널 | 쿼리 |
|---|------|------|
| 1 | DNS 쿼리 QPS | `rate(adguard_num_dns_queries[5m])` |
| 2 | 차단율 | `adguard_num_blocked_filtering / adguard_num_dns_queries * 100` |
| 3 | Top 클라이언트 (테이블) | `topk(10, adguard_top_clients)` |
| 4 | Top 차단된 도메인 | `topk(10, adguard_top_blocked_domains)` |
| 5 | 쿼리 타입 분포 (파이) | `adguard_query_types` |
| 6 | 평균 응답시간 | `adguard_avg_processing_time_seconds` |

---

## Task 3.4: Cloudflared Tunnel 대시보드

**Gate**: Task 0.2의 `cloudflared_tunnel_ha_connections` 관측 완료.

**Files (create)**: `manifests/monitoring/grafana/dashboards/apps/cloudflared.json`

**UID**: `app-cloudflared`.

**패널 (6개)**:

| # | 패널 | 쿼리 |
|---|------|------|
| 1 | HA 연결 수 | `cloudflared_tunnel_ha_connections` |
| 2 | 총 요청 수 | `rate(cloudflared_tunnel_total_requests[5m])` |
| 3 | HTTP 상태 코드별 | `rate(cloudflared_tunnel_response_by_code[5m])` by code |
| 4 | 연결 재시작 이벤트 | `increase(cloudflared_tunnel_concurrent_requests_per_tunnel[5m])` |
| 5 | 파드 CPU/Mem | container 메트릭 |
| 6 | 지난 1h 재시작 | `increase(kube_pod_container_status_restarts_total{namespace="networking"}[1h])` |

---

# Phase 4: 인프라 가시성

## Task 4.1: Traefik metrics 활성화 + 대시보드

**갭**: G4 — Traefik values.yaml에 metrics 없음 → Ingress L7 가시성 0.

**Files (modify/create)**:
- `manifests/infra/traefik/values.yaml` (Helm) — metrics 블록 추가
- `manifests/monitoring/grafana/dashboards/infra/traefik.json` (신규)

**values.yaml 패치**:

```yaml
metrics:
  prometheus:
    entryPoint: metrics
    addEntryPointsLabels: true
    addRoutersLabels: true
    addServicesLabels: true
    manualRouting: false
  prometheus.serviceMonitor:
    enabled: false  # ServiceMonitor CRD 없음 → annotation 사용

ports:
  metrics:
    port: 9100
    expose: false
    exposedPort: 9100
    protocol: TCP

service:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9100"
    prometheus.io/path: "/metrics"
```

**대시보드 UID**: `infra-traefik`.

**패널 (7개)**:

| # | 패널 | 쿼리 |
|---|------|------|
| 1 | 요청률 (router별) | `sum by(router) (rate(traefik_router_requests_total[5m]))` |
| 2 | 5xx 비율 | `sum(rate(traefik_router_requests_total{code=~"5.."}[5m])) / sum(rate(traefik_router_requests_total[5m]))` |
| 3 | P95 지연 | `histogram_quantile(0.95, rate(traefik_router_request_duration_seconds_bucket[5m]))` |
| 4 | entrypoint별 OPEN 커넥션 | `traefik_entrypoint_open_connections` |
| 5 | TLS 인증서 만료 | `traefik_tls_certs_not_after - time()` |
| 6 | service별 서버 상태 | `traefik_service_server_up` |
| 7 | 4xx 주요 라우트 | `topk(5, rate(traefik_router_requests_total{code=~"4.."}[5m]))` |

---

## Task 4.2: ArgoCD metrics 활성화 + 대시보드

**Files (modify/create)**:
- `manifests/infra/argocd/` (Application 또는 values.yaml) — controller/repo-server/server metrics 활성화
- `manifests/monitoring/grafana/dashboards/infra/argocd.json`

**argo-cd values 패치**:

```yaml
controller:
  metrics:
    enabled: true
    service:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8082"

server:
  metrics:
    enabled: true
    service:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8083"

repoServer:
  metrics:
    enabled: true
    service:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8084"
```

**UID**: `infra-argocd`.

**패널 (6개)**:
- App 건강도 분포 (`argocd_app_info` by health_status)
- Sync 실패 (`argocd_app_sync_total` by phase)
- OutOfSync 지속 시간 (`argocd_app_info{sync_status="OutOfSync"}`)
- Reconcile P95 (`histogram_quantile(0.95, argocd_app_reconcile_bucket)`)
- Repo Server git ops 에러
- Redis 연결 상태

---

## Task 4.3: CoreDNS 대시보드

**갭**: G4 — CoreDNS 기본 메트릭(`:9153/metrics`) 노출되지만 대시보드 없음. `coredns-restart` 알람의 역링크 타겟.

**Files (modify/create)**:
- CoreDNS Service annotation 확인 → kube-system ns이므로 직접 수정 어려움. `scrape-config.yaml`에 명시적 job 추가:

```yaml
- job_name: coredns
  kubernetes_sd_configs:
    - role: endpoints
      namespaces: { names: [kube-system] }
  relabel_configs:
    - source_labels: [__meta_kubernetes_service_label_k8s_app]
      regex: kube-dns
      action: keep
    - source_labels: [__address__]
      regex: (.+):\d+
      replacement: $1:9153
      target_label: __address__
```

- `manifests/monitoring/grafana/dashboards/infra/coredns.json`

**UID**: `infra-coredns`.

**패널 (6개)**:
- 쿼리율 (`rate(coredns_dns_requests_total[5m])`)
- 응답 코드 분포 (`coredns_dns_responses_total` by rcode)
- NXDOMAIN 비율
- P95 응답시간 (`histogram_quantile(0.95, coredns_dns_request_duration_seconds_bucket)`)
- 파드 재시작 (`increase(kube_pod_container_status_restarts_total{pod=~"coredns.*"}[1h])`)
- 캐시 hit/miss

---

## Task 4.4: Alloy + Grafana self-monitoring (선택)

**낮은 우선순위**. 감사 보고서 2.3항 — Alloy DaemonSet 자체 지표 없음.

Alloy는 `:12345/metrics`를 노출. `manifests/monitoring/alloy/daemonset.yaml`에 scrape annotation 추가 후 기본 패널 3~4개면 충분.

---

# Phase 5: 알람 UX 개선

## Task 5.1: 알람 현황 대시보드

**갭**: G5 — Telegram만 바라봐 이력 추적 불가.

**Files (create)**: `manifests/monitoring/grafana/dashboards/infra/alerts-overview.json`

**UID**: `infra-alerts-overview`.

**패널 (5개)**:

| # | 패널 | 쿼리 |
|---|------|------|
| 1 | 현재 발화 중 알람 (stat) | `count(ALERTS{alertstate="firing"})` |
| 2 | 발화 알람 상세 (table) | `ALERTS{alertstate="firing"}` |
| 3 | 24h 발화 추이 | `count by(alertname) (ALERTS{alertstate="firing"})` over time |
| 4 | Top 반복 알람 | `topk(5, count by(alertname) (changes(ALERTS_FOR_STATE[24h])))` |
| 5 | severity 분포 | `count by(severity) (ALERTS{alertstate="firing"})` |

---

## Task 5.2: 알람 규칙에 dashboardUid/runbook_url annotation 추가

**갭**: G7 — Telegram 알람에서 대시보드 점프 불가.

**Files (modify)**: `manifests/monitoring/grafana/alerting.yaml`

**매핑 테이블**:

| rule uid | dashboardUid | panelId | runbook_url |
|----------|--------------|---------|-------------|
| pod-crash-looping | `k8s-namespaces` | (재시작 패널 ID) | (홈랩 runbook, 또는 omit) |
| pod-not-ready | `k8s-namespaces` | (Pending 패널) | - |
| deployment-replicas-mismatch | `kube-state-metrics` | (Deployment 패널) | - |
| container-oom-killed | `k8s-pods` | (OOM 패널) | - |
| infra-pod-restart | `k8s-namespaces` | (networking 필터) | - |
| cluster-mass-restart | `k8s-cluster-global` | (Container Restarts) | `docs/disaster-recovery.md#cluster-mass-restart` |
| coredns-restart | `infra-coredns` | (재시작 패널) | - |
| node-memory-high | `k8s-nodes` | (메모리 패널) | - |
| node-disk-high | `k8s-nodes` | (디스크 패널) | - |
| node-cpu-high | `k8s-nodes` | (CPU 패널) | - |

각 rule의 `annotations` 블록에 추가:

```yaml
annotations:
  summary: "..."
  dashboardUid: k8s-namespaces
  panelId: "<실제 패널 ID>"
  # 선택: runbook_url: "https://github.com/.../docs/disaster-recovery.md#..."
```

Grafana는 `dashboardUid`/`panelId`가 있을 때 Telegram 메시지의 "상세보기" 링크를 해당 패널로 deep-link.

**패널 ID 찾는 방법**: 대시보드 JSON에서 관련 패널의 `"id": <숫자>` 확인.

---

## Task 5.3: cluster-mass-restart/coredns-restart 전용 시각화 패널

**갭**: 감사 보고서 5절 — 알람 9개 중 3개(infra/mass/coredns 재시작)가 대시보드 대응 패널 약함.

**Files (modify)**:
- `manifests/monitoring/grafana/dashboards/kubernetes/cluster-global.json` — "5분 내 동시 재시작 파드 수" 패널 추가
- `manifests/monitoring/grafana/dashboards/infra/coredns.json` (Task 4.3의 결과물) — 이미 재시작 패널 포함

**신규 패널 쿼리**: `count(max by(namespace, pod) (increase(kube_pod_container_status_restarts_total[5m])) > 0)` — 임계선 3으로 표시.

---

# Phase 6: 품질 정리

## Task 6.1: refresh/time 프로파일 정규화

**갭**: G8 — 일관성 떨어짐.

**규약**:
- 실시간 감시용 (cluster-global, namespaces, nodes, pods, logs-explorer, 앱·인프라 대시보드): `refresh: "30s"`, `time.from: "now-1h"`.
- 용량 예측용 (persistent-volumes, node-exporter-full): `refresh: "1m"`, `time.from: "now-24h"`.
- 스택 자체 (VM, VL, kube-state-metrics): `refresh: "30s"`, `time.from: "now-3h"`.

**Files**: 9 + 신규 대시보드 전체 (N개). jq 일괄 수정.

---

## Task 6.2: cluster-global vs kube-state-metrics-v2 포지셔닝 명확화

**갭**: G10 — 둘 다 "클러스터 전반"을 보여주는 중복.

**결정**:
- `cluster-global`: 엔트리 대시보드 — 현재 사용량·트래픽·알람 핫스팟.
- `kube-state-metrics-v2`: 리소스 인벤토리 — 객체 수·요청/제한·desired vs actual.

**변경**:
- cluster-global 상단에 "리소스 인벤토리는 [Kube State Metrics](/d/kube-state-metrics) 참고" 링크 row 추가.
- kube-state-metrics-v2 상단에도 역방향 링크.
- cluster-global에서 "Deployment 개수" 같은 인벤토리성 패널 제거 또는 축소.

---

# 최종 Deliverable 체크리스트

- [ ] Task 0.1~0.2: UID + cloudflared scrape (1~2시간)
- [ ] Task 1.1: 로그 대시보드 (3~4시간, dashboard-designer 활용)
- [ ] Task 2.1~2.3: 3개 앱 exporter 활성화 (각 1~2시간)
- [ ] Task 3.1~3.4: 4개 앱 대시보드 (각 2시간)
- [ ] Task 4.1~4.4: 4개 인프라 가시성 (각 2~3시간)
- [ ] Task 5.1~5.3: 알람 UX (합 3~4시간)
- [ ] Task 6.1~6.2: 정리 (1~2시간)

**총 추정**: 30~40시간 분량. 실제 실행은 Phase 단위 병렬화로 단축 가능.

# 추천 실행 순서 (최소 경로)

단일 세션 최소 마일스톤:

1. **Milestone 1 (2h)**: Task 0.1 (UID) + Task 0.2 (cloudflared) → 기반 검증.
2. **Milestone 2 (4h)**: Task 1.1 (로그 대시보드) — 독립적·가치 즉시 체감.
3. **Milestone 3 (8h)**: Task 2.1 + 3.1 (PostgreSQL end-to-end).
4. **Milestone 4 (4h)**: Task 2.2 + 3.2 (Uptime Kuma).
5. **Milestone 5 (6h)**: Task 2.3 + 3.3 + 3.4 (AdGuard + cloudflared 대시보드).
6. **Milestone 6 (8h)**: Phase 4 전체.
7. **Milestone 7 (4h)**: Phase 5.
8. **Milestone 8 (2h)**: Phase 6.

스프린트 단위로 Milestone 1~2 먼저, 나머지는 운영 여력에 맞춰 순차 진행 권장.

---

## 참고 문서

- 감사 보고서: `_workspace/grafana_dashboard_audit.md`
- 기존 대시보드 문서: `docs/grafana-dashboards.md`
- 재해복구 문서: `docs/disaster-recovery.md` (알람 runbook_url 링크 대상)
- 네임스페이스 전략: `docs/namespace-strategy.md`
- scrape 설정: `manifests/monitoring/victoria-metrics/scrape-config.yaml`
- 알람 규칙: `manifests/monitoring/grafana/alerting.yaml`
