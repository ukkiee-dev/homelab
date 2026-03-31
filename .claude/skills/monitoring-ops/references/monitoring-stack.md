# 모니터링 스택 레퍼런스

에이전트들이 참조하는 현재 모니터링 스택 구성 상세.

## 목차

1. [컴포넌트 엔드포인트](#컴포넌트-엔드포인트)
2. [메트릭 수집 파이프라인](#메트릭-수집-파이프라인)
3. [로그 수집 파이프라인](#로그-수집-파이프라인)
4. [알람 아키텍처](#알람-아키텍처)
5. [Grafana 프로비저닝](#grafana-프로비저닝)
6. [핵심 파일 경로](#핵심-파일-경로)

---

## 컴포넌트 엔드포인트

| 컴포넌트 | 서비스명 | 포트 | 네임스페이스 | 버전 |
|----------|---------|------|------------|------|
| VictoriaMetrics | `victoria-metrics` | 8428 | monitoring | v1.118.0 |
| VictoriaLogs | `victoria-logs` | 9428 | monitoring | v1.19.0 |
| Grafana | `grafana` | 3000 | monitoring | 12.0.0 |
| Alloy | (DaemonSet, 각 노드) | 12345 | monitoring | v1.8.0 |
| kube-state-metrics | `kube-state-metrics` | 8080 | monitoring | v2.13.0 |
| node-exporter | `node-exporter` | 9100 | monitoring | v1.8.2 |

## 메트릭 수집 파이프라인

```
[kube-state-metrics:8080] ──┐
[node-exporter:9100] ───────┤
[kubelet /metrics/cadvisor] ┼──→ VictoriaMetrics (promscrape) ──→ Grafana
[Pod prometheus.io/*] ──────┤     port 8428, retention 30d
[Service prometheus.io/*] ──┘
```

### VictoriaMetrics Scrape Jobs (5개)

| Job | 대상 | 발견 방식 |
|-----|------|----------|
| `kubernetes-nodes` | kubelet 메트릭 | K8s SD role: node, API proxy 경유 |
| `kubernetes-pods` | Pod 커스텀 메트릭 | K8s SD role: pod, `prometheus.io/scrape=true` 필터 |
| `kubernetes-service-endpoints` | Service 엔드포인트 | K8s SD role: endpoints, `prometheus.io/scrape=true` 필터 |
| `kube-state-metrics` | K8s 객체 메트릭 | Static config |
| `node-exporter` | 호스트 메트릭 | Static config |

### 앱에 메트릭 수집을 활성화하려면

Deployment의 `spec.template.metadata.annotations`에 추가:

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "<메트릭_포트>"
  prometheus.io/path: "/metrics"  # 기본값, 다르면 명시
```

## 로그 수집 파이프라인

```
[Pod stdout/stderr] ──→ Alloy DaemonSet ──→ VictoriaLogs
                        (K8s discovery)      port 9428
                        라벨: namespace,     Loki 호환 API
                        pod, container       retention 15d
```

- Alloy는 K8s API로 모든 Pod를 자동 발견한다 (설정 불필요)
- 라벨 3개 자동 추가: `namespace`, `pod`, `container`
- 앱이 stdout/stderr에 로그를 출력하면 자동 수집됨
- 파일 로그만 쓰는 앱은 수집 안 됨 → stdout 리다이렉트 필요

## 알람 아키텍처

```
VictoriaMetrics ──→ Grafana Unified Alerting ──→ Telegram Bot
                    7 rules, 2 groups              HTML 메시지
                    eval interval: 1m              한국어 알림
```

### 프로비저닝 구조

ConfigMap `grafana-alerting`의 `alerting.yaml`:

```yaml
# 3개 키를 포함:
contactpoints.yaml:   # Telegram contact point 정의
policies.yaml:        # 알림 정책 (group_by, wait, interval, repeat)
rules.yaml:           # 알람 규칙 그룹 + 개별 규칙
```

### 알람 규칙 3단계 패턴 (모든 규칙 동일)

```yaml
data:
  - refId: A   # PromQL instant 쿼리
    datasourceUid: victoriametrics
    model: { expr: "<PromQL>", instant: true }
  - refId: B   # reduce: last
    datasourceUid: __expr__
    model: { type: reduce, reducer: last, expression: A }
  - refId: C   # threshold: gt <값>
    datasourceUid: __expr__
    model: { type: threshold, expression: B, conditions: [...] }
```

### Notification Policy

- group_by: `[grafana_folder, alertname]`
- group_wait: 30s
- group_interval: 5m
- repeat_interval: 4h
- receiver: Telegram

## Grafana 프로비저닝

| 대상 | 프로비저닝 방식 | 파일/경로 |
|------|---------------|----------|
| 데이터소스 | ConfigMap → `/etc/grafana/provisioning/datasources/` | `datasources.yaml` |
| 알람 | ConfigMap → `/etc/grafana/provisioning/alerting/` | `alerting.yaml` |
| 대시보드 | PVC 직접 저장 (UI/API로 관리) | `/var/lib/grafana/` |

데이터소스 UID:
- VictoriaMetrics: `victoriametrics` (타입: `prometheus`)
- VictoriaLogs: 자동 생성 (타입: `victoriametrics-logs-datasource`)

## 핵심 파일 경로

| 용도 | 경로 |
|------|------|
| 모니터링 Kustomization | `manifests/monitoring/kustomization.yaml` |
| Grafana 알람 규칙 | `manifests/monitoring/grafana/alerting.yaml` |
| Grafana 데이터소스 | `manifests/monitoring/grafana/datasources.yaml` |
| Grafana Deployment | `manifests/monitoring/grafana/deployment.yaml` |
| VM Scrape Config | `manifests/monitoring/victoria-metrics/scrape-config.yaml` |
| Alloy 설정 | `manifests/monitoring/alloy/config.yaml` |
| VM Deployment | `manifests/monitoring/victoria-metrics/deployment.yaml` |
| VLogs Deployment | `manifests/monitoring/victoria-logs/deployment.yaml` |
