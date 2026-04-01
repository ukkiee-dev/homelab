# K8s 메모리 최적화 — 남은 작업

> 작성: 2026-04-01 | 선행 완료: Phase 0~3 Git 변경 + ArgoCD/Reloader helm upgrade

---

## 1. PostgreSQL helm upgrade (Phase 2.5)

**전제조건**: cadvisor 24h 피크 데이터 확보 후 (Phase 0.5에서 scrape config 추가 완료)

```bash
# 실행 전 24h 피크 확인 (Grafana 또는 PromQL)
# max_over_time(container_memory_working_set_bytes{container="postgresql", namespace="apps"}[24h])

helm upgrade postgresql oci://registry-1.docker.io/bitnamicharts/postgresql -n apps \
  --reuse-values \
  --set primary.resources.requests.memory=48Mi \
  --set primary.resources.limits.memory=96Mi

# 변경된 values Git에 업데이트
helm get values -a postgresql -n apps > manifests/apps/postgresql/helm-values.yaml
```

**검증**:
```bash
kubectl get pods -n apps -l app.kubernetes.io/name=postgresql -o custom-columns="NAME:.metadata.name,REQ:.spec.containers[0].resources.requests.memory,LIM:.spec.containers[0].resources.limits.memory"
```

---

## 2. ResourceQuota 재활성화 (Phase 3.4)

**전제조건**: 모든 helm upgrade 완료 + 워크로드가 새 리소스 값으로 안정 실행 확인

**현재 상태**: `manifests/infra/scheduling/kustomization.yaml`에서 ResourceQuota 8개가 주석 처리됨.

**작업**:
1. kustomization.yaml에서 ResourceQuota 주석 해제
2. 커밋 + 푸시
3. ArgoCD scheduling app이 자동 sync로 적용

```yaml
# manifests/infra/scheduling/kustomization.yaml 에서 아래 주석 해제:
  - resourcequota-immich.yaml
  - resourcequota-argocd.yaml
  - resourcequota-monitoring.yaml
  - resourcequota-apps.yaml
  - resourcequota-tailscale-system.yaml
  - resourcequota-traefik-system.yaml
  - resourcequota-networking.yaml
  - resourcequota-test-web.yaml
```

**주의**: 활성화 전 반드시 현재 사용량이 quota 이하인지 확인:
```bash
for ns in argocd immich monitoring apps tailscale-system traefik-system networking test-web; do
  echo "=== $ns ==="
  kubectl top pods -n $ns --no-headers 2>/dev/null | awk '{sum+=$3} END {print "memory used:", sum"Mi"}'
done
```

---

## 3. ArgoCD image-updater 리소스 조정 (Phase 2.3 잔여)

image-updater는 별도 Helm release(`argocd-image-updater`)로 관리됨. 본 최적화에서 아직 미처리.

**목표**: req 64→32Mi, lim 128→48Mi

```bash
# image-updater Helm release 확인
helm list -n argocd --filter image-updater

# 업그레이드 (values 파일 확인 후)
helm upgrade argocd-image-updater argo/argocd-image-updater -n argocd \
  --reuse-values \
  --set resources.requests.memory=32Mi \
  --set resources.limits.memory=48Mi
```

---

## 4. Phase 4: kubelet eviction threshold

**방안 A**: K3s kubelet arg 설정 (OrbStack 지원 시)
```bash
# /etc/rancher/k3s/config.yaml에 추가
--kubelet-arg="eviction-hard=memory.available<100Mi,nodefs.available<5%,imagefs.available<5%"
--kubelet-arg="eviction-soft=memory.available<200Mi,nodefs.available<10%"
--kubelet-arg="eviction-soft-grace-period=memory.available=30s,nodefs.available=1m"
```

**방안 B**: OrbStack에서 kubelet 설정 불가 시
1. PriorityClass + ResourceQuota만으로 보호 (이미 적용됨)
2. OrbStack VM 메모리 증설: 12Gi → 16Gi
3. Grafana 알람: `node_memory_MemAvailable_bytes < 500Mi` 시 알림

---

## 5. 적용 과정에서 발견된 이슈 (참고)

### ArgoCD Helm v4 + server-side apply 충돌
- `configs.cm.accounts.ukkiee` 필드가 argocd-server에 의해 관리되어 Helm field manager 충돌 발생
- **해결**: values.yaml에서 해당 필드 제거, argocd-server가 직접 관리하도록 위임
- `manifests/infra/argocd/values.yaml`에 주석으로 기록됨

### ArgoCD Helm chart의 deploymentStrategy 제한
- `deploymentStrategy.type: Recreate` 설정 시 chart 기본 `rollingUpdate` 파라미터와 충돌
- **해결**: ArgoCD values에서 deploymentStrategy 제거 (기본 RollingUpdate 유지)
- 단일 노드 환경에서 RollingUpdate가 일시적으로 2x request를 사용하지만, ResourceQuota 여유분(x1.34)으로 대응

### ResourceQuota 적용 순서 문제
- ResourceQuota를 helm upgrade 전에 적용하면 기존 (높은) limit의 파드가 quota를 초과하여 새 파드 생성 차단
- **해결**: ResourceQuota를 kustomization에서 주석 처리 → 모든 워크로드 리소스 조정 완료 후 재활성화

---

## 검증 PromQL (24h 데이터 축적 후)

```promql
# 파드별 24h 피크
max_over_time(container_memory_working_set_bytes{container!=""}[24h])

# 파드별 24h 평균
avg_over_time(container_memory_working_set_bytes{container!=""}[24h])

# evictable 메모리 비율
container_memory_cache / container_memory_usage_bytes

# OOM 이벤트
kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}
```
