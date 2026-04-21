# CNPG Webhook Deadlock Escape — M3 비상 절차

> **작성일**: 2026-04-21 (Phase 9 Task 9.1)
> **대상**: CNPG operator 의 validating/mutating webhook 이 CR 삭제·변경을 거부하여 클러스터가 잠기는 비상 상황
> **전제**: `kubectl` + cluster-admin 권한 (로컬에서 `kubectl -n cnpg-system get deploy` 접근 가능)
> **참조**: design v0.4 §9 M3 · `feedback_cert_manager_cainjector_limits.md` memory

---

## 1. 증상

CNPG operator 의 webhook 이 응답하지 않거나 reject 하여 `Cluster`/`Database`/`ObjectStore`/`Backup` CR 의 생성·수정·삭제가 모두 막힌 상태.

### 대표 에러 메시지

```
Error from server (InternalError): error when creating "cluster.yaml":
  Internal error occurred: failed calling webhook "vcluster.cnpg.io":
  failed to call webhook: Post "https://cnpg-webhook-service.cnpg-system.svc:443/validate-postgresql-cnpg-io-v1-cluster?timeout=10s":
  context deadline exceeded
```

```
Error from server: admission webhook "mcluster.cnpg.io" denied the request:
  (varies — certificate verify failed / connection refused / tls handshake timeout)
```

### 자주 같이 나타나는 Alert

- `CertManagerCainjectorRestart` (cert-manager CRD cache sync timeout)
- `CNPGOperatorDown` (operator pod CrashLoopBackOff)
- `ApplicationOutOfSync` (ArgoCD 가 CR apply 실패)

---

## 2. 진단

### Step 1 — operator 상태 확인

```bash
kubectl -n cnpg-system get pods
kubectl -n cnpg-system describe deploy cnpg-controller-manager | tail -30
kubectl -n cnpg-system logs deploy/cnpg-controller-manager --tail=80
kubectl -n cnpg-system logs deploy/cnpg-controller-manager --previous --tail=80 2>/dev/null || true
```

**판단 기준**:
- Pod 가 `Running + Ready=1/1` 이 아니면 → **§3 A (operator 자체 장애)**
- Pod 는 정상인데 webhook 만 실패 → **§3 B (cert-manager 인증서 문제)**
- Pod 도 webhook 도 정상인데 CR validation 이 영구 거부 → **§3 C (validating rule 버그)**

### Step 2 — webhook 인증서 상태

```bash
kubectl -n cnpg-system get cert,certificaterequest,order,challenge 2>&1 | head -20
kubectl -n cnpg-system describe cert cnpg-webhook-cert | tail -30
kubectl -n cert-manager get pods
kubectl -n cert-manager logs deploy/cert-manager-cainjector --tail=50
```

**판단 기준**:
- `Cert cnpg-webhook-cert` 가 `Ready=False` 이거나 `Status: Issuing` 에서 멈춤 → cert-manager 문제
- `cainjector` CrashLoopBackOff → memory `feedback_cert_manager_cainjector_limits.md` 참조 (64Mi/100m limit 금지)

### Step 3 — ValidatingWebhookConfiguration 확인

```bash
kubectl get validatingwebhookconfiguration cnpg-validating-webhook-configuration -o yaml | yq '.webhooks[] | {name, failurePolicy, clientConfig: .clientConfig.service}'
kubectl get mutatingwebhookconfiguration cnpg-mutating-webhook-configuration -o yaml | yq '.webhooks[] | {name, failurePolicy, clientConfig: .clientConfig.service}'
```

**판단 기준**:
- `failurePolicy: Fail` (기본값) 이고 webhook unreachable → **어떤 CR 작업도 불가 = 데드락**
- `cnpg-system/cnpg-webhook-service` 로 정확히 매핑됐는지 확인

### Step 4 — Service · Endpoint 확인

```bash
kubectl -n cnpg-system get svc,endpoints
# webhook service 의 endpoint 가 empty 면 operator pod 가 ready=false 상태
```

---

## 3. 해결

### 시나리오 A: operator pod 자체가 죽은 경우

1. **원인 확인** (OOM, 설정 오류, CRD 캐시 sync 실패 등)
   ```bash
   kubectl -n cnpg-system describe pod -l app.kubernetes.io/name=cloudnative-pg | grep -A5 "Last State\|Reason\|Events"
   ```
2. **Git 매니페스트 수정** (SelfHeal 이 원복하므로 kubectl patch 는 일시적)
   - `manifests/infra/cnpg-operator/values.yaml` 에 리소스 limits 상향 또는 설정 수정
   - commit + push → ArgoCD sync
3. **수동 재기동** (Git 변경 반영이 시급하지 않은 경우)
   ```bash
   kubectl -n cnpg-system rollout restart deploy/cnpg-controller-manager
   kubectl -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=120s
   ```

### 시나리오 B: cert-manager 인증서 문제

1. **cainjector 복구 (가장 흔한 원인)**
   - `kubectl -n cert-manager describe pod -l app=cainjector` 에서 OOM 확인
   - memory `feedback_cert_manager_cainjector_limits.md` 참조: `limits.memory >= 256Mi`, `limits.cpu >= 500m` 으로 조정
   - `manifests/infra/cert-manager/values.yaml` 수정 + Git push → ArgoCD sync
2. **인증서 강제 재발급**
   ```bash
   kubectl -n cnpg-system delete secret cnpg-webhook-cert      # Certificate 가 재발급
   kubectl -n cnpg-system delete certificaterequest --all
   # cert-manager 가 새 CSR → Issue → Secret 생성
   kubectl -n cnpg-system wait --for=condition=Ready cert/cnpg-webhook-cert --timeout=120s
   ```
3. **ValidatingWebhookConfiguration 의 CA bundle 재주입 확인**
   ```bash
   kubectl get validatingwebhookconfiguration cnpg-validating-webhook-configuration \
     -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | base64 -d | openssl x509 -noout -dates
   ```
   cainjector 가 최신 CA 를 bundle 에 주입해야 함. 오래된 값이면 cainjector 재기동 후 대기.

### 시나리오 C: validating rule 버그 (operator 정상인데 거부)

**최후의 수단 — operator scale 0 escape** (design §9 M3):

```bash
# 1. operator 일시 중지 → webhook 비활성 → CR 작업 가능
kubectl -n cnpg-system scale deploy/cnpg-controller-manager --replicas=0

# 2. 이제 blocked 되던 CR 작업 실행
kubectl -n <project> delete cluster <cluster-name>
# 또는 patch 등

# 3. operator 즉시 복구
kubectl -n cnpg-system scale deploy/cnpg-controller-manager --replicas=1
kubectl -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=120s
```

> **주의**:
> - operator down 기간 동안 기존 Cluster 관리 (failover, reconcile) 가 멈춤 — **3 분 이내 작업 권장**
> - scale 0 상태에서 새 Cluster/Database CR 을 만들면 operator 가 reconcile 하지 않음 (단순 YAML 만 생성됨)
> - 복구 후 `kubectl -n <project> get cluster` 가 phase `Cluster in healthy state` 인지 확인

### 대체 방법 — webhook failurePolicy 임시 변경 (권장도 ↓)

```bash
# 위험: 모든 validation 이 우회됨. 장기간 유지 금지
kubectl patch validatingwebhookconfiguration cnpg-validating-webhook-configuration \
  --type='json' -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'

# 복구 후 즉시 원복
kubectl patch validatingwebhookconfiguration cnpg-validating-webhook-configuration \
  --type='json' -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Fail"}]'
```

Helm chart 는 `Fail` 을 권장값으로 설정하므로 ArgoCD sync 가 곧 원복. 하지만 **operator scale 0 이 더 안전** (webhook 은 그대로, operator 만 멈춤).

---

## 4. 검증

### Step 1 — operator & webhook 건강성

```bash
kubectl -n cnpg-system get pods
# cnpg-controller-manager: 1/1 Ready

kubectl -n cnpg-system get endpoints cnpg-webhook-service -o jsonpath='{.subsets[*].addresses[*].ip}'
# non-empty IP 출력

kubectl -n cnpg-system get cert cnpg-webhook-cert -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# True
```

### Step 2 — CR 작업 정상화

```bash
# 신규 Cluster 생성 dry-run 으로 webhook 응답 확인
kubectl -n <project> run --rm -it --restart=Never webhook-check --image=busybox -- \
  sh -c 'sleep 1'  # 실제 CR 생성 대신 간단한 동작 확인

# 또는: 실제로 blocked 된 작업 재시도
kubectl -n <project> apply -f cluster.yaml
kubectl -n <project> get cluster <name> -o jsonpath='{.status.phase}'
# "Cluster in healthy state" 또는 진행 중 phase
```

### Step 3 — 기존 Cluster 건강성

```bash
kubectl -n <project> get cluster
kubectl -n <project> get pod -l cnpg.io/cluster=<name>
# 모든 cluster 가 healthy, pod 가 Ready
```

### Step 4 — ArgoCD 재동기화 확인

```bash
kubectl get application -A | grep -E "cnpg|<project>" | awk '{print $1,$5,$6}'
# SYNC STATUS: Synced, HEALTH STATUS: Healthy
```

---

## 5. 사후 조치

- **incident timeline 기록**: `_workspace/cnpg-incidents/YYYY-MM-DD-webhook-deadlock.md` 생성
- **재발 방지 분석**:
  - cainjector OOM: 리소스 limit 상향 확정 PR
  - validating rule 버그: CNPG upstream issue 검색·보고
  - operator CrashLoop: 메모리/CPU 부족이면 limits 상향
- **monitoring 보강**: `CNPGOperatorDown` 알람 임계·대기시간 점검
- **Runbook 업데이트**: 이 문서에 새로 발견한 escape 패턴 추가

---

## 6. 자주 묻는 질문

**Q. operator scale 0 하면 기존 DB 가 죽나요?**
A. 아니요. operator 는 "선언 기반 관리자" 로, 없어도 기존 Pod·Service·PVC 는 그대로 동작합니다. 다만 failover·scaling·backup 은 reconcile 안 됨.

**Q. `failurePolicy: Ignore` 로 영구 두면 안 되나요?**
A. 비추천. validation 없이는 잘못된 CR 이 상태를 깨뜨려도 감지 못함. 긴급 시에만 **수분 단위** 로 사용.

**Q. cert-manager 미설치 상태에서 CNPG 만 복구하려면?**
A. 불가능. CNPG chart 는 cert-manager 의 `Certificate` CRD 를 사용해 webhook cert 를 자동 생성합니다. cert-manager 가 먼저 Ready 여야 합니다 (Phase 1 순서 강제 이유).

**Q. operator 복구 후 Cluster phase 가 여전히 `Upgrading` 등에서 멈춰있다면?**
A. 해당 Cluster 의 status 를 직접 확인: `kubectl -n <ns> get cluster <name> -o jsonpath='{.status.conditions}'`. reconcile 이 트리거되지 않으면 annotation 토글:
```bash
kubectl -n <ns> annotate cluster <name> cnpg.io/reconciliationLoop=enabled --overwrite
```

---

## 7. 관련 문서

- design v0.4 §9 M3 (webhook 데드락 정책)
- memory `feedback_cert_manager_cainjector_limits.md` — cainjector 리소스 하한선
- memory `project_cnpg_cluster_drift_pattern.md` — CNPG Cluster CR drift 무시 패턴
- Runbook `cnpg-new-project.md` — 신규 프로젝트 생성 시 webhook 의존
- Runbook `cnpg-upgrade.md` — operator 업그레이드 중 webhook 재인증서 발급
