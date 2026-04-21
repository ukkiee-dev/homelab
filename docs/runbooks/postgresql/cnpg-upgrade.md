# CNPG 업그레이드 Runbook — Operator · Plugin · Postgres

> **작성일**: 2026-04-21 (Phase 9 Task 9.1)
> **대상**: CNPG operator · plugin-barman-cloud · PostgreSQL image 업그레이드
> **전제**: Phase 1-5 완료, 모든 Cluster Healthy, Renovate 가 PR 을 생성한 상태
> **참조**: design v0.4 §D3 Renovate 정책 + §D15 업그레이드 메서드 + memory `project_cnpg_cluster_drift_pattern.md`

---

## 0. 핵심 원칙

### Renovate 정책 (homelab/renovate.json 에 pin 됨)

| 패키지 | 자동 merge | 메이저 | 정책 |
|--------|------------|--------|------|
| `cloudnative-pg` Helm chart | ❌ | 차단 | 수동 리뷰, `cnpg-stack` 그룹 |
| `cert-manager` Helm chart | ❌ | 차단 | 수동 리뷰, `cnpg-stack` 그룹 |
| `ghcr.io/cloudnative-pg/postgresql` image | ✅ (minor만) | 차단 | **minor 자동** — `primaryUpdateStrategy: unsupervised` 전제 |
| `plugin-barman-cloud` GH release | ❌ | 수동 | 개별 리뷰 |

### 업그레이드 순서 (Phase 1 의 3-stack 역순)

1. **cert-manager** 업그레이드 최우선 (CNPG webhook 인증서 발급 의존)
2. **CNPG operator** (cloudnative-pg chart)
3. **plugin-barman-cloud** (operator 와 독립, CNPG v1.26+ 호환성 확인)
4. **PostgreSQL image** (각 Cluster 의 `spec.imageName` — Renovate 가 PR 생성)

---

## 1. 증상 (업그레이드 트리거)

### 자동 트리거

- Renovate dashboard 에 업그레이드 PR 개방 (매 월요일 6 AM 스캔)
- GHCR postgres minor image 자동 PR (Renovate automerge=true)

### 수동 트리거

- CVE 발표 후 긴급 패치
- upstream release note 의 버그 fix 필요
- operator 버전 EOL 임박

---

## 2. 진단 — 사전 점검

### Step 1 — 현재 버전 확인

```bash
# Operator chart
helm -n cnpg-system list
# 또는
kubectl -n cnpg-system get deploy cnpg-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}'

# Plugin
kubectl -n cnpg-system get deploy plugin-barman-cloud -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || \
  kubectl -n cnpg-system get deploy -l app.kubernetes.io/name=plugin-barman-cloud -o jsonpath='{.items[0].spec.template.spec.containers[0].image}'

# Cluster postgres image
kubectl get cluster -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.spec.imageName}{"\n"}{end}'

# cert-manager
kubectl -n cert-manager get deploy cert-manager -o jsonpath='{.spec.template.spec.containers[0].image}'
```

### Step 2 — 릴리즈 노트 확인

- CNPG operator: `https://github.com/cloudnative-pg/cloudnative-pg/releases`
- plugin-barman-cloud: `https://github.com/cloudnative-pg/plugin-barman-cloud/releases`
- PostgreSQL: `https://www.postgresql.org/docs/release/`

**확인 포인트**:
- **Breaking changes**: CRD schema, API version, removed fields
- **Migration notes**: operator 가 자동 migrate 하는지, 수동 step 필요한지
- **Webhook 변경**: `ValidatingWebhookConfiguration` rule 재작성 여부
- **Postgres major 여부**: 16 → 17 은 `pg_upgrade` 또는 dump/restore 필요 (이 Runbook 범위 밖, 별도 계획)

### Step 3 — 백업 건강성 확인 (반드시)

```bash
# 최근 ScheduledBackup 성공 시점
kubectl get scheduledbackup -A
kubectl get backup -A --sort-by=.status.startedAt | tail -10

# WAL archive lag
kubectl get cluster -A -o jsonpath='{range .items[*]}{.metadata.name}: lastArchivedWAL={.status.lastArchivedWAL}, lastArchivedWALTime={.status.lastArchivedWALTime}{"\n"}{end}'
```

**기준**:
- 모든 Cluster 의 `status.conditions[?(@.type=="ArchivingWAL")].status=True`
- 최근 24h 내 base backup 성공
- WAL archive time 이 5 분 이내

### Step 4 — 현재 클러스터 상태

```bash
kubectl get cluster -A -o wide
# READY 열이 모두 1/1, STATUS=healthy

kubectl get pod -A -l cnpg.io/cluster -o wide
# 모든 pod Running + Ready
```

실패 중인 Cluster 가 있으면 **업그레이드 중단** 하고 `cnpg-new-project.md` 트러블슈팅 먼저.

---

## 3. 해결 — 업그레이드 시나리오별 절차

### 시나리오 A: CNPG operator chart upgrade (minor/patch)

다운타임 SLO: **~30 초** (operator pod 재시작, DB pod 는 영향 없음).

#### Step 1 — Renovate PR 리뷰

1. GitHub PR 에서 `CHANGELOG.md` 확인 (breaking 없는지)
2. `manifests/infra/cnpg-operator/kustomization.yaml` 의 chart version 변경 확인
3. values.yaml override 가 새 버전 schema 와 호환되는지 (removed keys 여부)

#### Step 2 — 운영자 사전 공지

Telegram 알림 (1 시간 전):
```
🔧 CNPG operator 업그레이드 예정 — <시각> ~ +5분
- operator 재시작 ~30초, DB 가용성 영향 없음
- Cluster reconcile 일시 중지 (~1분)
- Runbook: docs/runbooks/postgresql/cnpg-upgrade.md
```

#### Step 3 — Merge & 관찰

```bash
# 1. PR merge (assignee=사용자, merge=Claude 규약)
gh pr merge <N> --squash --delete-branch

# 2. ArgoCD sync 대기 (auto-sync 라면 자동)
kubectl get application cnpg-operator -n argocd -w
# 5-10 초 내 Synced + Healthy

# 3. operator rollout 확인
kubectl -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=120s
```

#### Step 4 — webhook 인증서 상태

```bash
kubectl -n cnpg-system get cert,certificaterequest
# Ready=True 필수

kubectl -n cnpg-system get endpoints cnpg-webhook-service
# endpoint 에 pod IP 존재
```

인증서 재발급 실패 시 → `cnpg-webhook-deadlock-escape.md` §3 시나리오 B

#### Step 5 — 기존 Cluster reconcile 확인

```bash
kubectl get cluster -A -w
# 모든 Cluster 가 continue 되는지 (drift 발생 가능)

# drift 발생 시 (design 메모리에서 예측됨):
kubectl get application <app> -n argocd -o jsonpath='{.status.sync.status}'
# OutOfSync 가 지속되면 jsonPointers ignoreDifferences 추가 필요 → project_cnpg_cluster_drift_pattern.md
```

### 시나리오 B: cert-manager upgrade

**반드시 CNPG operator 와 분리 · 먼저 수행**.

#### Step 1 — cainjector 리소스 유지 확인

PR diff 에서 `values.yaml` 의 `cainjector.resources` 가 감소하지 않았는지 (`feedback_cert_manager_cainjector_limits.md`: min 256Mi/500m)

#### Step 2 — Merge & 관찰

```bash
gh pr merge <N> --squash --delete-branch

# ArgoCD 에서 cert-manager sync
kubectl -n cert-manager rollout status deploy/cert-manager cert-manager-webhook cert-manager-cainjector --timeout=120s
```

#### Step 3 — CNPG webhook cert 재검증

```bash
kubectl -n cnpg-system get cert cnpg-webhook-cert -o jsonpath='{.status.conditions[?(@.type=="Ready")]}'
# status=True

# Operator pod 재기동 없이도 webhook 정상 동작 확인
kubectl -n cnpg-system get endpoints cnpg-webhook-service
```

장애 시: `cnpg-webhook-deadlock-escape.md` §2 Step 2.

### 시나리오 C: plugin-barman-cloud upgrade

다운타임 SLO: **WAL archive 수초 중단** (plugin pod restart).

#### Step 1 — operator 호환성 확인

plugin release note 에 minimum CNPG operator 버전 명시. 조건 불충족 시 operator 먼저 업그레이드.

#### Step 2 — WAL archive pause 준비 (선택적)

긴 업그레이드 시간 예상 시:
```bash
# 해당 Cluster 의 scheduledBackup 일시 suspend
kubectl -n <project> patch scheduledbackup <name> --type=merge -p '{"spec":{"suspend":true}}'
```

#### Step 3 — Merge & rollout

```bash
gh pr merge <N> --squash --delete-branch
kubectl -n cnpg-system rollout status deploy -l app.kubernetes.io/name=plugin-barman-cloud --timeout=120s
```

#### Step 4 — plugin 로그 확인

```bash
kubectl -n cnpg-system logs deploy -l app.kubernetes.io/name=plugin-barman-cloud --tail=50 | grep -i "error\|fail"
```

`recovery` 또는 `archive` 관련 fatal 에러 시 즉시 rollback.

#### Step 5 — WAL archive 재개 + 다음 백업 확인

```bash
kubectl -n <project> patch scheduledbackup <name> --type=merge -p '{"spec":{"suspend":false}}'
# 다음 scheduledBackup 주기 또는 수동 Backup 로 검증
kubectl -n <project> create -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: upgrade-smoke-$(date +%s)
spec:
  cluster:
    name: <cluster-name>
EOF
kubectl -n <project> get backup -w
# Completed + <target> 표시
```

### 시나리오 D: PostgreSQL image upgrade (minor)

다운타임 SLO: **30 초 – 2 분** (pod restart + DB shutdown checkpoint).
Renovate `automerge: true` 로 설정되어 있으므로 자동 merge 후 ArgoCD sync.

#### Step 1 — automerge 동작 확인

```bash
# Renovate dashboard 에서 최근 automerge 한 PR 확인
# 커밋: "chore: update ghcr.io/cloudnative-pg/postgresql to 16.x"
```

#### Step 2 — Cluster reconcile 관찰

```bash
kubectl get cluster -A -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.imageName}{"\n"}{end}'
# imageName 반영 여부

kubectl get pod -A -l cnpg.io/cluster -w
# 각 Cluster 의 pod 가 Terminating → ContainerCreating → Running 재시작
```

#### Step 3 — primary switchover 모니터

```bash
kubectl -n <project> get cluster <name> -o jsonpath='{.status.phase}'
# "Upgrading instances" 또는 "Switchover in progress" → "Cluster in healthy state"
```

#### Step 4 — 애플리케이션 연결 복구 확인

```bash
# 앱 pod 가 DB 연결 끊겼다가 재연결되는지 로그 확인
kubectl -n <app> logs -l app.kubernetes.io/name=<svc> --tail=30 | grep -i "database\|connection"
```

readiness probe 가 DB 연결 체크하면 일시적으로 Pod Ready=false 가 되었다가 복구. Service 는 ready pod 만 라우팅하므로 외부 장애 없음 (1 인스턴스라 short downtime 불가피).

### 시나리오 E: Postgres major upgrade (16 → 17 등)

**이 Runbook 범위 밖**. 별도 계획 문서 필요.

- `pg_upgrade` in-place 또는 logical dump/restore
- CNPG 의 `imageCatalogRef` + `major-version-upgrade` plugin 고려
- 단일 인스턴스 환경에서 10 분 이상 다운타임
- **Phase 9 이후 별도 마이그레이션으로 계획**

---

## 4. 검증 (모든 시나리오 공통)

### Step 1 — 버전 반영 확인

```bash
# Operator
kubectl -n cnpg-system get deploy cnpg-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}'

# Cluster
kubectl get cluster -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.spec.imageName}{"\n"}{end}'
```

### Step 2 — 상태 Healthy

```bash
kubectl get cluster -A
# 모두 READY=1/1, STATUS=healthy

kubectl get application -A | grep -iE "cnpg|cert-manager" | awk '{print $1, $5, $6}'
# 모두 Synced + Healthy
```

### Step 3 — Backup 재개 확인

```bash
# 업그레이드 후 첫 scheduledBackup 성공 확인
kubectl get backup -A --sort-by=.status.startedAt | tail -5
# 최근 Backup phase=Completed
```

### Step 4 — 앱 연결 복구

```bash
# 각 Cluster 참조하는 앱이 정상 동작
kubectl get pod -A --field-selector=status.phase!=Running 2>/dev/null | grep -v NAMESPACE
# 비어있어야 함
```

### Step 5 — 메트릭/알람 정상

- Grafana 대시보드 `CloudNativePG Cluster` 패널이 수치 정상 (TPS, connections, cache hit)
- 1 시간 내 신규 알람 발화 없음

---

## 5. Rollback

### Operator/plugin/cert-manager chart rollback

```bash
# git revert → ArgoCD 가 이전 버전으로 downgrade
git revert <upgrade-commit>
git push origin main
# ArgoCD selfHeal 자동 동기화
```

### Postgres image rollback

```bash
# git 에서 이전 tag 로 되돌림 (Renovate automerge 가 한 커밋 revert)
git revert <postgres-image-update-commit>
git push origin main

# Cluster 가 자동 downgrade 재시작
kubectl get pod -n <project> -l cnpg.io/cluster=<name> -w
```

**주의**: Postgres major 버전은 downgrade 불가 (`pg_upgrade` 역방향 없음). minor 만 되돌림 가능.

---

## 6. 자주 묻는 질문

**Q. Renovate 가 Postgres minor automerge 를 했는데 업무시간에 들어갔어요. 괜찮나요?**
A. Renovate `schedule: "before 6am on Monday"` 로 제한했지만 실제 쓸 시점은 Cluster reconcile 타이밍. 1 인스턴스 환경에서 30 초 – 2 분 단기 DB 중단이 발생하므로, 민감한 앱 (결제, 실시간 등) 이 있으면 automerge=false 로 전환 고려.

**Q. operator 버전 N → N+2 를 한 번에 점프해도 되나요?**
A. CNPG 공식 문서가 권장하지 않음 — N → N+1 → N+2 로 단계적 진행. migration logic 이 연속 버전 기준.

**Q. plugin 이 operator 보다 높은 버전이어도 되나요?**
A. 보통 낮춰야 함. plugin release note 의 `required CNPG version` 확인 필수.

**Q. 업그레이드 중 drift (design memory `project_cnpg_cluster_drift_pattern`) 가 새로 나타났어요.**
A. 신규 CNPG 버전이 추가 default 필드를 채웠을 가능성. `argocd/applications/apps/<app>.yaml` 의 `ignoreDifferences.jsonPointers` 또는 `jqPathExpressions` 에 경로 추가 + PR.

**Q. cert-manager 업그레이드 후 CNPG webhook 이 Fail 입니다.**
A. `cnpg-webhook-deadlock-escape.md` §3 시나리오 B 참조. cainjector 복구 → cert 재발급 순서.

---

## 7. 관련 문서

- design v0.4 §D3 (Renovate 정책 · 업그레이드 메서드)
- design v0.4 §D15 (Postgres 파라미터 pin)
- Runbook `cnpg-webhook-deadlock-escape.md` (M3 escape)
- Runbook `cnpg-new-project.md` (Cluster 생성 · drift 처리)
- memory `project_cnpg_cluster_drift_pattern.md` (CNPG default 필드 ignoreDifferences)
- memory `feedback_cert_manager_cainjector_limits.md` (cainjector 리소스 하한)
- `renovate.json` (cnpg-stack, cnpg-postgres-image, cnpg-barman-plugin 규칙)
