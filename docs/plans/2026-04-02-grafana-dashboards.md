# Grafana 대시보드 프로비저닝 구현 계획

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Grafana에 커뮤니티 대시보드를 ConfigMap 기반 프로비저닝으로 배포하여 GitOps 관리되는 모니터링 대시보드를 구축한다.

**Architecture:** Grafana의 dashboard provisioning 기능을 활용한다. ConfigMap에 대시보드 JSON을 저장하고, Grafana deployment에 provisioning volume을 추가한다. 대시보드 JSON은 Grafana.com API에서 다운로드하여 datasource uid를 `victoriametrics`로 치환한 후 ConfigMap으로 저장한다. 대시보드는 Phase 1(필수 5개) → Phase 2(확장 4개) 순으로 배포한다.

**Tech Stack:** Grafana 12.0.0, Kustomize, ConfigMap provisioning, VictoriaMetrics (prometheus type, uid: victoriametrics)

---

## 사전 지식

### Grafana Dashboard Provisioning 구조

```
/etc/grafana/provisioning/dashboards/
  dashboards.yaml          ← provider 설정 (어디서 JSON을 읽을지)

/var/lib/grafana/dashboards/    ← 실제 대시보드 JSON 파일들
  cluster-global.json
  node-exporter.json
  ...
```

### 현재 Grafana 구조

- **Deployment**: `manifests/monitoring/grafana/deployment.yaml`
- **Datasource**: VictoriaMetrics (uid: `victoriametrics`), VictoriaLogs
- **Alerting**: ConfigMap으로 프로비저닝 중
- **Dashboard**: 미설정 ← 이번에 추가

### datasource uid 치환 규칙

커뮤니티 대시보드는 보통 `${DS_PROMETHEUS}` 또는 특정 uid를 사용한다.
모두 `victoriametrics`로 치환해야 한다:
- `"datasource": "Prometheus"` → `"datasource": {"type": "prometheus", "uid": "victoriametrics"}`
- `"uid": "${DS_PROMETHEUS}"` → `"uid": "victoriametrics"`
- `"datasource": {"type": "prometheus", "uid": "..."}` → uid를 `victoriametrics`로

---

## Phase 1: 프로비저닝 인프라 + 필수 대시보드 5개

### Task 1: Dashboard provisioning provider 설정

**Files:**
- Create: `manifests/monitoring/grafana/dashboard-provider.yaml`

**Step 1: provider ConfigMap 작성**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-provider
  namespace: monitoring
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
data:
  dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: default
        orgId: 1
        folder: ''
        type: file
        disableDeletion: false
        updateIntervalSeconds: 30
        allowUiUpdates: true
        options:
          path: /var/lib/grafana/dashboards
          foldersFromFilesStructure: true
```

**Step 2: 커밋**

```bash
git add manifests/monitoring/grafana/dashboard-provider.yaml
git commit -m "feat: Grafana 대시보드 프로비저닝 provider 설정 추가"
```

---

### Task 2: Grafana deployment에 dashboard volume 추가

**Files:**
- Modify: `manifests/monitoring/grafana/deployment.yaml`

**Step 1: volumeMounts에 추가** (containers[0].volumeMounts에)

```yaml
            - name: dashboard-provider
              mountPath: /etc/grafana/provisioning/dashboards
              readOnly: true
            - name: dashboards-kubernetes
              mountPath: /var/lib/grafana/dashboards/kubernetes
              readOnly: true
            - name: dashboards-node
              mountPath: /var/lib/grafana/dashboards/node
              readOnly: true
            - name: dashboards-workload
              mountPath: /var/lib/grafana/dashboards/workload
              readOnly: true
```

**Step 2: volumes에 추가** (spec.volumes에)

```yaml
        - name: dashboard-provider
          configMap:
            name: grafana-dashboard-provider
        - name: dashboards-kubernetes
          configMap:
            name: grafana-dashboards-kubernetes
        - name: dashboards-node
          configMap:
            name: grafana-dashboards-node
        - name: dashboards-workload
          configMap:
            name: grafana-dashboards-workload
```

**Step 3: 커밋**

```bash
git add manifests/monitoring/grafana/deployment.yaml
git commit -m "feat: Grafana deployment에 대시보드 프로비저닝 volume 추가"
```

---

### Task 3: 대시보드 JSON 다운로드 및 datasource 치환

**Files:**
- Create: `manifests/monitoring/grafana/dashboards/kubernetes/cluster-global.json` (ID: 15757)
- Create: `manifests/monitoring/grafana/dashboards/kubernetes/namespaces.json` (ID: 15758)
- Create: `manifests/monitoring/grafana/dashboards/kubernetes/pods.json` (ID: 15760)
- Create: `manifests/monitoring/grafana/dashboards/node/node-exporter-full.json` (ID: 1860)
- Create: `manifests/monitoring/grafana/dashboards/workload/kube-state-metrics-v2.json` (ID: 21742)

**Step 1: 다운로드 스크립트 실행**

각 대시보드 JSON을 Grafana.com API에서 다운로드한다:

```bash
# 디렉토리 생성
mkdir -p manifests/monitoring/grafana/dashboards/{kubernetes,node,workload}

# 다운로드 + datasource uid 치환
for item in "15757:kubernetes/cluster-global" "15758:kubernetes/namespaces" "15760:kubernetes/pods" "1860:node/node-exporter-full" "21742:workload/kube-state-metrics-v2"; do
  ID="${item%%:*}"
  PATH_NAME="${item#*:}"
  curl -sL "https://grafana.com/api/dashboards/${ID}/revisions/latest/download" \
    | sed 's/${DS_PROMETHEUS}/victoriametrics/g' \
    | jq '(.panels[]?.datasource // empty) |= (if type == "string" and (. == "Prometheus" or . == "prometheus") then {"type": "prometheus", "uid": "victoriametrics"} elif type == "object" and .type == "prometheus" then .uid = "victoriametrics" else . end)' \
    | jq '.templating.list[]?.datasource |= (if type == "string" and (. == "Prometheus" or . == "prometheus") then {"type": "prometheus", "uid": "victoriametrics"} elif type == "object" and .type == "prometheus" then .uid = "victoriametrics" else . end)' \
    | jq 'walk(if type == "object" and .datasource?.type? == "prometheus" then .datasource.uid = "victoriametrics" else . end)' \
    | jq '.id = null | .uid = null' \
    > "manifests/monitoring/grafana/dashboards/${PATH_NAME}.json"
  echo "Downloaded: ${PATH_NAME} (ID: ${ID})"
done
```

**Step 2: JSON 파일 크기 확인**

```bash
wc -c manifests/monitoring/grafana/dashboards/**/*.json
```

> 참고: ConfigMap은 1MiB 제한이 있다. 대시보드 JSON이 클 경우 별도 ConfigMap으로 분리해야 한다.
> Node Exporter Full(1860)은 ~300KB로 큰 편이므로 단독 ConfigMap이 적절하다.

**Step 3: 커밋**

```bash
git add manifests/monitoring/grafana/dashboards/
git commit -m "feat: 필수 대시보드 5개 JSON 추가 (dotdc 3종 + node-exporter + KSM v2)"
```

---

### Task 4: 대시보드 ConfigMap 매니페스트 생성

**Files:**
- Create: `manifests/monitoring/grafana/dashboards/kubernetes/kustomization.yaml`
- Create: `manifests/monitoring/grafana/dashboards/node/kustomization.yaml`
- Create: `manifests/monitoring/grafana/dashboards/workload/kustomization.yaml`
- Create: `manifests/monitoring/grafana/dashboards/kustomization.yaml`

> ConfigMap generator를 사용하면 JSON 파일을 자동으로 ConfigMap에 담을 수 있다.
> 하지만 ArgoCD와의 호환성을 위해 generatorOptions에 disableNameSuffixHash를 설정한다.

**Step 1: 각 하위 kustomization 작성**

`manifests/monitoring/grafana/dashboards/kubernetes/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: monitoring
generatorOptions:
  disableNameSuffixHash: true
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
configMapGenerator:
  - name: grafana-dashboards-kubernetes
    files:
      - cluster-global.json
      - namespaces.json
      - pods.json
```

`manifests/monitoring/grafana/dashboards/node/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: monitoring
generatorOptions:
  disableNameSuffixHash: true
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
configMapGenerator:
  - name: grafana-dashboards-node
    files:
      - node-exporter-full.json
```

`manifests/monitoring/grafana/dashboards/workload/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: monitoring
generatorOptions:
  disableNameSuffixHash: true
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
configMapGenerator:
  - name: grafana-dashboards-workload
    files:
      - kube-state-metrics-v2.json
```

`manifests/monitoring/grafana/dashboards/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - kubernetes
  - node
  - workload
```

**Step 2: 커밋**

```bash
git add manifests/monitoring/grafana/dashboards/
git commit -m "feat: 대시보드 ConfigMap kustomize generator 설정"
```

---

### Task 5: Grafana kustomization에 dashboards 리소스 추가

**Files:**
- Modify: `manifests/monitoring/grafana/kustomization.yaml`

**Step 1: dashboards 리소스 추가**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: monitoring
resources:
  - pvc.yaml
  - deployment.yaml
  - service.yaml
  - datasources.yaml
  - alerting.yaml
  - ingressroute.yaml
  - sealed-secret.yaml
  - telegram-sealed-secret.yaml
  - dashboard-provider.yaml
  - dashboards
```

**Step 2: kustomize build 검증**

```bash
kustomize build manifests/monitoring/grafana/ | head -20
```

Expected: ConfigMap 리소스들이 정상 생성됨

**Step 3: 전체 monitoring kustomize 검증**

```bash
kustomize build manifests/monitoring/ | grep "kind: ConfigMap" | head -10
```

Expected: grafana-dashboards-kubernetes, grafana-dashboards-node, grafana-dashboards-workload 포함

**Step 4: 커밋**

```bash
git add manifests/monitoring/grafana/kustomization.yaml
git commit -m "feat: Grafana kustomization에 대시보드 프로비저닝 리소스 등록"
```

---

### Task 6: Push & ArgoCD 동기화 확인

**Step 1: Push**

```bash
git push origin main
```

**Step 2: ArgoCD 동기화 대기**

```bash
# hard refresh 트리거
kubectl patch application monitoring -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# 동기화 상태 확인 (30초 대기)
sleep 30
kubectl get application monitoring -n argocd -o jsonpath='sync={.status.sync.status} health={.status.health.status}'
```

Expected: `sync=Synced health=Healthy` 또는 `health=Progressing`

**Step 3: Grafana 파드 재시작 확인**

```bash
kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana
```

Expected: 새 파드가 생성되어 Running 상태 (volume 변경으로 재시작됨)

**Step 4: 대시보드 로드 검증**

```bash
# Grafana API로 대시보드 목록 확인
GRAFANA_POD=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n monitoring $GRAFANA_POD -- curl -s http://localhost:3000/api/search 2>/dev/null | jq '.[].title'
```

Expected: 5개 대시보드 제목이 출력됨

---

## Phase 2: 확장 대시보드 4개

### Task 7: 확장 대시보드 JSON 다운로드

**Files:**
- Create: `manifests/monitoring/grafana/dashboards/kubernetes/nodes.json` (ID: 15759)
- Create: `manifests/monitoring/grafana/dashboards/kubernetes/persistent-volumes.json` (ID: 15600)
- Create: `manifests/monitoring/grafana/dashboards/workload/victoriametrics.json` (ID: 10229)
- Create: `manifests/monitoring/grafana/dashboards/workload/victorialogs.json` (ID: 22084)

**Step 1: 다운로드 + 치환**

```bash
for item in "15759:kubernetes/nodes" "15600:kubernetes/persistent-volumes" "10229:workload/victoriametrics" "22084:workload/victorialogs"; do
  ID="${item%%:*}"
  PATH_NAME="${item#*:}"
  curl -sL "https://grafana.com/api/dashboards/${ID}/revisions/latest/download" \
    | jq 'walk(if type == "object" and .datasource?.type? == "prometheus" then .datasource.uid = "victoriametrics" else . end)' \
    | sed 's/${DS_PROMETHEUS}/victoriametrics/g' \
    | jq '.id = null | .uid = null' \
    > "manifests/monitoring/grafana/dashboards/${PATH_NAME}.json"
  echo "Downloaded: ${PATH_NAME} (ID: ${ID})"
done
```

**Step 2: kustomization 파일 업데이트**

`manifests/monitoring/grafana/dashboards/kubernetes/kustomization.yaml` — files에 추가:
```yaml
      - nodes.json
      - persistent-volumes.json
```

`manifests/monitoring/grafana/dashboards/workload/kustomization.yaml` — files에 추가:
```yaml
      - victoriametrics.json
      - victorialogs.json
```

**Step 3: ConfigMap 크기 검증**

```bash
# 각 ConfigMap의 예상 크기 확인 (1MiB = 1048576 bytes 이내여야 함)
for dir in kubernetes node workload; do
  SIZE=$(cat manifests/monitoring/grafana/dashboards/$dir/*.json 2>/dev/null | wc -c)
  echo "$dir: ${SIZE} bytes"
done
```

> 만약 kubernetes ConfigMap이 1MiB를 초과하면, persistent-volumes.json을 별도 ConfigMap으로 분리한다.

**Step 4: kustomize build 검증**

```bash
kustomize build manifests/monitoring/ > /dev/null && echo "OK" || echo "FAIL"
```

**Step 5: 커밋 & Push**

```bash
git add manifests/monitoring/grafana/dashboards/
git commit -m "feat: 확장 대시보드 4개 추가 (nodes, PVC, VictoriaMetrics, VictoriaLogs)"
git push origin main
```

---

### Task 8: 최종 검증

**Step 1: ArgoCD 동기화 확인**

```bash
kubectl patch application monitoring -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
sleep 30
kubectl get application monitoring -n argocd -o jsonpath='sync={.status.sync.status}'
```

Expected: `Synced`

**Step 2: 전체 대시보드 목록 검증**

```bash
GRAFANA_POD=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n monitoring $GRAFANA_POD -- curl -s http://localhost:3000/api/search 2>/dev/null | jq -r '.[].title'
```

Expected: 9개 대시보드 제목 출력

**Step 3: 실제 데이터 렌더링 확인**

브라우저에서 `grafana.ukkiee.dev`에 접속하여:
1. Kubernetes / Views / Global → 클러스터 CPU/Memory 게이지에 데이터 표시 확인
2. Node Exporter Full → 노드 메트릭 그래프 렌더링 확인
3. Kubernetes / Views / Pods → 파드 드롭다운에 파드 목록 표시 확인

> 만약 "No data" 패널이 있다면: 해당 패널의 쿼리를 Explore에서 직접 실행하여 메트릭 존재 여부 확인

---

## 체크리스트

- [ ] Task 1: Dashboard provisioning provider ConfigMap 생성
- [ ] Task 2: Grafana deployment에 volume/volumeMount 추가
- [ ] Task 3: 필수 대시보드 5개 JSON 다운로드 + datasource 치환
- [ ] Task 4: ConfigMap kustomize generator 설정
- [ ] Task 5: Grafana kustomization에 리소스 등록 + kustomize build 검증
- [ ] Task 6: Push & ArgoCD 동기화 + 대시보드 로드 검증
- [ ] Task 7: 확장 대시보드 4개 추가 + 크기 검증
- [ ] Task 8: 최종 검증 (9개 대시보드 로드 + 데이터 렌더링)

---

## 롤백 계획

문제 발생 시:
1. `manifests/monitoring/grafana/kustomization.yaml`에서 `dashboard-provider.yaml`과 `dashboards` 줄 제거
2. deployment.yaml에서 추가한 volumeMounts/volumes 제거
3. 커밋 & push → ArgoCD가 이전 상태로 복원
