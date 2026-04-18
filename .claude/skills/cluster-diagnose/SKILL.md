---
name: cluster-diagnose
description: "K3s 클러스터 진단 체크리스트와 트러블슈팅 절차. 파드 장애, 리소스 부족, 네트워크 문제, 스토리지 이슈, ArgoCD 동기화 실패 등 클러스터 문제 진단 시 사용한다. 'pod 안 뜸', '장애', 'CrashLoop', 'OOM', 'ImagePullBackOff', 'Pending', '동기화 실패', 'OutOfSync', 'PVC 마운트', '노드 리소스', 'kubectl', '로그 분석', '디버깅', '왜 안 돼' 등 클러스터 문제 관련 키워드에 반응."
---

# 클러스터 진단 가이드

## 진단 원칙

1. **증거 수집 우선**: 가설을 세우기 전에 로그, 이벤트, 리소스 상태를 먼저 수집한다
2. **근본 원인 추적**: 표면 증상이 아니라 왜 발생했는지를 파고든다
3. **비파괴적 진단**: 읽기 명령만 사용. 변경 명령은 사용자 확인 후
4. **Git 경유 수정**: 매니페스트 변경은 kubectl이 아니라 파일 수정으로 — ArgoCD selfHeal이 원복하므로

## 증상별 진단 체크리스트

### CrashLoopBackOff

```bash
# 1. 현재 상태 확인
kubectl describe pod <pod> -n <ns>

# 2. 현재 로그 (있으면)
kubectl logs <pod> -n <ns> --tail=50

# 3. 이전 컨테이너 로그 (crash 전)
kubectl logs <pod> -n <ns> --previous --tail=100

# 4. OOM 여부 확인 — Last State에서 Reason: OOMKilled 확인
kubectl get pod <pod> -n <ns> -o jsonpath='{.status.containerStatuses[0].lastState}'
```

**흔한 원인**: OOM (memory limit 부족), 설정 오류 (ConfigMap/Secret 누락), health check 실패, 의존 서비스 미준비

### ImagePullBackOff

```bash
kubectl describe pod <pod> -n <ns> | grep -A5 "Events"
```

**흔한 원인**: 이미지 태그 오타, GHCR pull secret 누락/만료, private registry 인증 실패

### Pending

```bash
# 1. 스케줄링 실패 원인
kubectl describe pod <pod> -n <ns> | grep -A3 "Events"

# 2. 노드 리소스 확인
kubectl describe node | grep -A10 "Allocated resources"

# 3. PVC Pending이면
kubectl get pvc -n <ns>
kubectl describe pvc <pvc> -n <ns>
```

**흔한 원인**: 리소스 부족 (CPU/Memory), PVC 바인딩 실패, nodeSelector/affinity 불일치

### Pod 정상이지만 접근 불가

```bash
# 1. Service → Pod 연결 확인
kubectl get endpoints <svc> -n <ns>

# 2. IngressRoute 확인
kubectl get ingressroute -n <ns> -o yaml

# 3. NetworkPolicy 확인 — 트래픽이 차단되는지
kubectl get networkpolicy -n <ns> -o yaml

# 4. Traefik 로그 확인
kubectl logs -l app.kubernetes.io/name=traefik -n traefik-system --tail=50
```

**흔한 원인**: Service selector ↔ Pod label 불일치, NetworkPolicy 차단, IngressRoute 오설정, Traefik entryPoint 오류

### ArgoCD OutOfSync / SyncFailed

```bash
# 1. Application 상태
kubectl get application <app> -n argocd
kubectl describe application <app> -n argocd

# 2. 동기화 이력
kubectl get application <app> -n argocd -o jsonpath='{.status.sync}'

# 3. 리소스별 동기화 상태
kubectl get application <app> -n argocd -o jsonpath='{.status.resources[?(@.status!="Synced")]}'
```

**흔한 원인**: 매니페스트 YAML 오류, 네임스페이스 불일치, CRD 미설치 (sync wave 문제), Helm values 충돌

### 리소스 부족 (노드)

```bash
# 1. 노드 리소스 요약
kubectl top nodes

# 2. Pod별 실제 사용량
kubectl top pods -A --sort-by=memory

# 3. requests vs 실제 사용 비교
kubectl describe node | grep -A20 "Allocated resources"
```

**참고**: K3s 시스템 오버헤드 ~2.3Gi (kubelet + apiserver + etcd). OrbStack 12Gi 할당 기준 앱에 ~9.7Gi 가용.

### 스토리지 / PVC 문제

```bash
# PV/PVC 상태
kubectl get pv,pvc -A

# hostPath PV 확인 (있다면 호스트 마운트 필요)
kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.hostPath.path}{"\n"}{end}'

# 외장 볼륨 사용 시 마운트 확인 (예: /Volumes/ukkiee/)
ls -la /Volumes/ukkiee/ 2>/dev/null
```

**흔한 원인**: hostPath 디렉토리 권한, PV/PVC 바인딩 모드, local-path-provisioner 상태

## 모니터링 연동

### VictoriaMetrics 쿼리 (Grafana 또는 직접)

```bash
# 메모리 사용 상위 5 Pod
curl -s 'http://victoria-metrics.monitoring:8428/api/v1/query?query=topk(5,container_memory_working_set_bytes{namespace!="kube-system"})'

# CPU 사용 상위 5 Pod
curl -s 'http://victoria-metrics.monitoring:8428/api/v1/query?query=topk(5,rate(container_cpu_usage_seconds_total[5m]))'

# 재시작 횟수
curl -s 'http://victoria-metrics.monitoring:8428/api/v1/query?query=kube_pod_container_status_restarts_total>0'
```

### Grafana 알림 임계치 (현재 설정)

| 알림 | 조건 | 대기 |
|------|------|------|
| CrashLoopBackOff | 10분 내 3+ restarts | 5m |
| Pod not ready | readiness 실패 | 15m |
| OOM killed | 즉시 | 0m |
| Memory > 85% | 노드 메모리 | 5m |
| Disk > 85% | 노드 디스크 | 10m |
| CPU > 90% | 노드 CPU | 10m |

## OrbStack 특이사항

- **K3s 재시작**: `orb restart k8s` — 모든 Pod이 재스케줄링됨. StatefulSet은 PVC 대기 후 복구
- **네트워크 리셋**: OrbStack 재시작 시 Tailscale/Cloudflare Tunnel 재연결 필요 (보통 자동)
- **hostPath PV**: 외부 볼륨(`/Volumes/ukkiee/` 등)을 참조하는 PV가 있다면 macOS 호스트에서 해당 볼륨이 마운트된 상태여야 함. 현재 활성 워크로드에 hostPath PV는 없음 (모두 local-path-provisioner)
- **로그 위치**: OrbStack 컨테이너 로그는 `kubectl logs`로 접근. 호스트 로그는 OrbStack 앱에서 확인
