# Grafana 대시보드 리서치

> 조사일: 2026-04-02
> 환경: K3s 단일 노드 (OrbStack/Mac Mini), VictoriaMetrics, Grafana 12.0.0
> 설치된 exporter: node-exporter, kube-state-metrics, Alloy (로그 → VictoriaLogs)

## 핵심 결론

- **dotdc/grafana-dashboards-kubernetes** 세트가 커뮤니티 표준 (GitHub 3.5k star, Grafana Labs 공식 솔루션 배지)
- VictoriaMetrics k8s-stack에서도 내장 사용할 정도로 호환성 검증됨
- K3s 전용 대시보드보다 범용 대시보드가 더 실용적

## VictoriaMetrics 호환성

| 항목 | 상태 | 비고 |
|------|------|------|
| PromQL 쿼리 | 완전 호환 | MetricsQL이 PromQL 상위집합 |
| Prometheus 타입 datasource | 호환 | 현재 설정 그대로 사용 가능 |
| Recording Rules | 주의 | kube-prometheus recording rules → VMRule 변환 필요 |
| 테이블 패널 | 호환 | VM v1.42.0+에서 해결됨 |

---

## 권장 대시보드 세트

### 필수 (Core) — 5개

| 순위 | ID | 이름 | 용도 | 작성자 |
|------|-----|------|------|--------|
| 1 | **15757** | Kubernetes / Views / Global | 클러스터 전체 개요 | dotdc (공식 배지) |
| 2 | **15758** | Kubernetes / Views / Namespaces | 네임스페이스별 리소스 | dotdc (공식 배지) |
| 3 | **15760** | Kubernetes / Views / Pods | Pod/컨테이너 상세 | dotdc (공식 배지) |
| 4 | **1860** | Node Exporter Full | 노드 하드웨어/OS 상세 | rfmoz |
| 5 | **21742** | Kube State Metrics v2 | 워크로드 건강도 + PVC | Grafana Labs |

### 확장 (Extended) — 4개

| 순위 | ID | 이름 | 용도 | 작성자 |
|------|-----|------|------|--------|
| 6 | **15759** | Kubernetes / Views / Nodes | K8s 관점 노드 상태 | dotdc |
| 7 | **15600** | kubernetes-persistent-volumes-custom | PVC 사용량 (네임스페이스 구분) | 커뮤니티 |
| 8 | **10229** | VictoriaMetrics - single-node | VM 자체 모니터링 | VictoriaMetrics |
| 9 | **22084** | VictoriaLogs - single-node | VL 자체 모니터링 | VictoriaMetrics |

### 선택 (Optional) — 3개

| 순위 | ID | 이름 | 용도 | 비고 |
|------|-----|------|------|------|
| 10 | **15154** | Workload Resource Recommendations | right-sizing 추천 | recording rule 필요 |
| 11 | **15762** | Kubernetes / System / CoreDNS | DNS 문제 진단 | dotdc 세트 |
| 12 | **15661** | K8S Dashboard (EN) | 올인원 대안 | 단일 대시보드 선호 시 |

---

## 카테고리별 상세

### 1. 클러스터 전체 개요

#### dotdc - Kubernetes / Views / Global (ID: 15757) — 1순위

- **필요 메트릭**: kube-state-metrics, node-exporter, cAdvisor
- **VM 호환**: VictoriaMetrics k8s-stack에서 내장 사용, 호환 확인
- **특징**: 클러스터 전체 CPU/Memory/Network, 네임스페이스별 리소스 분포, 모던 time-series 패널

#### 대안

| ID | 이름 | 특징 | 비고 |
|----|------|------|------|
| 15661 | K8S Dashboard (EN) | 4가지 뷰 올인원 | 중국어 원본(13105) 번역판, 2025-01-25 업데이트 |
| 6417 | Kubernetes Cluster (Prometheus) | 컨테이너 요약 | Grafana Labs, 비교적 오래됨 |

### 2. 노드 상세

#### Node Exporter Full (ID: 1860) — 1순위

- **필요 메트릭**: node-exporter (`--collector.systemd --collector.processes` 권장)
- **VM 호환**: v1.42.0+에서 완전 호환
- **특징**: node-exporter 제공 거의 모든 메트릭 시각화 (CPU, Memory, Disk, Network, Filesystem)
- **장점**: 업계 사실상 표준, 지속적 업데이트
- **단점**: 패널 수가 매우 많아 단일 노드에서는 과할 수 있음

#### 대안

| ID | 이름 | 특징 | 비고 |
|----|------|------|------|
| 15759 | Kubernetes / Views / Nodes | K8s 컨텍스트 노드 뷰 | dotdc 세트, 가벼움 |
| 22413 | K8s Node Metrics 2025 | Grafana 11+ 호환, 멀티클러스터 | 단일 노드에는 과함 |

### 3. Pod/컨테이너 리소스

#### dotdc - Kubernetes / Views / Pods (ID: 15760) — 1순위

- **필요 메트릭**: kube-state-metrics, node-exporter, cAdvisor
- **특징**: 컨테이너별 CPU/Memory + 네트워크 + 파일시스템, 모던 패널

#### 대안

| ID | 이름 | 특징 |
|----|------|------|
| 21298 | Kubernetes Pod Dashboard | Pod CPU/Memory/Network I/O |
| 9810 | Kubernetes Pods/Containers Resources | Pod/컨테이너별 리소스 |

### 4. 네임스페이스 리소스

#### dotdc - Kubernetes / Views / Namespaces (ID: 15758) — 1순위

- **필요 메트릭**: kube-state-metrics, node-exporter, cAdvisor
- **특징**: 네임스페이스별 CPU/Memory/Network, Pod 상태, 스토리지

#### 대안

| ID | 이름 | 특징 |
|----|------|------|
| 15826 | K8s monitoring by namespace & instance | 네임스페이스 + 인스턴스 필터링, PVC 포함 |
| 17375 | K8s Resource Monitoring | request/limit 총합, ResourceQuota 결정에 활용 |

### 5. 워크로드 건강도

#### Kube State Metrics v2 (ID: 21742) — 1순위

- **필요 메트릭**: kube-state-metrics v2+
- **특징**:
  - 리소스 카운트 (pods, deployments, statefulsets, jobs, PVCs)
  - QoS 클래스 분포 시각화
  - CPU/Memory 사용률 네임스페이스별 분석
  - PVC 바인딩 상태, HPA 성능 메트릭

#### 대안

| ID | 이름 | 특징 | 비고 |
|----|------|------|------|
| 15777 | Deployment/StatefulSet/DaemonSet metrics | 클러스터 전체 워크로드 CPU/Memory | 741회 다운로드 |
| 15160 | Deployment Performance & Health | RED + USE 메트릭, OOMKill 추적 | Istio 패널은 빈 상태 |

### 6. 스토리지/PVC

#### kubernetes-persistent-volumes-custom (ID: 15600) — 1순위

- **필요 메트릭**: kubelet PV/PVC 메트릭
- **특징**: 원본(13646) 대비 네임스페이스 구분 버그 수정

#### 대안

| ID | 이름 | 특징 |
|----|------|------|
| 23233 | Kubernetes PVC Stats | PV/PVC + Ceph RBD (Ceph 미사용 시 무시) |
| 22429 | PersistentVolume Overview | 숫자 중복 표시 버그 수정판 |

### 7. 네트워크

#### Kubernetes / Networking / Pod (ID: 12661)

- **작성자**: Grafana Labs
- **필요 메트릭**: cAdvisor (container_network_*)
- **특징**: Pod 레벨 RX/TX 대역폭
- **참고**: dotdc Views/Pods(15760), Views/Namespaces(15758)에도 네트워크 패널 포함되어 별도 불필요할 수 있음

### 8. VictoriaMetrics/VictoriaLogs 자체 모니터링

| ID | 이름 | 다운로드 | 용도 |
|----|------|---------|------|
| **10229** | VictoriaMetrics - single-node | 311k | VM 상태/성능 (ingestion rate, query latency, storage) |
| **22084** | VictoriaLogs - single-node | 26k | VL 상태 (로그 ingestion, 디스크, slow query) |
| 12683 | VictoriaMetrics - vmagent | 1.7M | vmagent 스크래핑 파이프라인 |
| 22759 | VictoriaLogs Explorer | — | VL 데이터 탐색용 인터랙티브 |

### 9. Right-Sizing 도구

#### Workload Resource Recommendations (ID: 15154)

- **필요**: kubelet cAdvisor + kube-state-metrics + recording rule (`node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate`)
- **특징**: 과거 사용량 기반 request/limit 추천, percentile/overhead 조절 가능
- **주의**: VictoriaMetrics에서 VMRule로 recording rule 생성 필요
- **활용**: "피크24h x 1.3" right-sizing 정책과 보완적으로 사용 가능

---

## K3s 전용 대시보드 (비추천)

| ID | 이름 | 비고 |
|----|------|------|
| 16450 | K3s Cluster | Grafana Labs 공식 배지, 기능 제한적 |
| 19972 | K3S Monitoring | kube-prometheus 의존 |
| 15282 | K3S cluster monitoring | RKE 파생, 업데이트 드묾 |

> K3s는 표준 K8s API를 따르므로 범용 대시보드(dotdc 세트)가 더 풍부한 정보를 제공한다.
> K3s 전용은 cAdvisor에만 의존하는 반면, dotdc는 kube-state-metrics + node-exporter + cAdvisor를 모두 활용.

---

## 대시보드 컬렉션/스타터킷

### dotdc/grafana-dashboards-kubernetes (가장 권장)

- **구성**: 8개 대시보드 (Views 4 + System 2 + Addons 2)
- **설치**: JSON import, ConfigMap provisioning, Terraform, Helm
- **GitHub**: https://github.com/dotdc/grafana-dashboards-kubernetes

### kube-prometheus-stack (참고)

- **구성**: Prometheus + Grafana + Alertmanager + exporter + recording rules + 다수 내장 대시보드
- **주의**: 매니페스트 기반 환경이므로 대시보드만 별도 import 필요

### VictoriaMetrics K8s Stack (참고)

- **구성**: kube-prometheus 파생 대시보드 + recording rules + VM 자체 대시보드
- **Docs**: https://docs.victoriametrics.com/helm/victoria-metrics-k8s-stack/

---

## Import 방법

Grafana UI에서 **Dashboards → Import → Dashboard ID 입력 → Load → datasource를 VictoriaMetrics 선택 → Import**

---

## 추가 조사 필요

- Grafana 12 호환성: 대부분 Grafana 11까지 테스트됨 (일반적으로 하위 호환)
- Alloy 자체 모니터링 대시보드: /metrics 엔드포인트 노출하므로 별도 대시보드 존재 가능
- immich 전용 대시보드: Prometheus 메트릭 노출 시 전용 대시보드 가능
