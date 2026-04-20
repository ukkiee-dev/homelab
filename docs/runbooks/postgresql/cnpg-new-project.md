# CNPG 신규 프로젝트 DB 추가 — 수동 + 자동화 경로

> **작성일**: 2026-04-21 (Phase 7 C 테스트 가이드 겸 Phase 9 Runbook 의 첫 편)
> **대상**: 새 프로젝트·앱에 CNPG PostgreSQL DB 추가
> **전제**: Phase 1-5 완료 (cert-manager / CNPG operator / plugin / monitoring 모두 Healthy)

## 사용 시나리오

A. **기존 앱 레포에 DB 추가** — 이미 homelab 에 배포된 앱에 DB 만 연결
B. **신규 프로젝트 + DB 동시 생성** — 새 앱 레포 + homelab 매니페스트 + DB 한 번에
C. **수동 템플릿 복사** — 자동화 우회 (긴급 수정, 참조 구조 필요 시)

기본 권장 = **시나리오 B (GHA workflow dispatch 자동화)**.

## 시나리오 B: GHA workflow 자동화 (권장)

### 사전 준비

1. 앱 GitHub 레포 생성: `ukkiee-dev/<app>` (org 템플릿 기반)
2. 앱 레포의 `.app-config.yml` 작성 (선택 사항, 없어도 setup-app 동작):
   ```yaml
   health: /health
   icon: mdi-book-open-variant
   description: <app 설명>
   ```
3. homelab 레포의 `.github/workflows/create-app.yml` (caller) 가 `_create-app.yml` 을 호출하는 것 확인

### 실행

homelab 레포에서 workflow dispatch:

```
Actions → Create App → Run workflow
  app-name:        <app>
  app-type:        web                 # static | web | worker
  service-name:    api                 # 모노레포 서비스 이름 (DB 활성화 시 필수)
  database-enabled: true
  database-mode:   owner
  database-name:   <db>                # DB 이름 (예: wiki, api)
  database-role:   <role>              # 비우면 service-name 기본값
  database-storage: 10Gi               # 기본값, 필요 시 상향
```

**주의사항**:
- `service-name` 비우면 flat 앱으로 간주 → database composite 가 skip (warning). flat 앱 DB 는 현재 미지원 — 모노레포 구조 필수.
- `database-mode=owner` 만 이번 버전 지원. `reference` / `reference-readonly` 는 후속 확장.

### 자동 처리 단계 (composite action 이 수행)

1. ✅ `apps.json` + Terraform DNS (기존 setup-app)
2. ✅ Cloudflare Tunnel ingress (기존)
3. ✅ 앱 Deployment / Service / IngressRoute / NetworkPolicy / GHCR pull secret (기존)
4. ✅ ArgoCD Application 생성
5. ✅ **DB 매니페스트 생성** (Phase 7 신규):
   - `common/` 에 cluster/objectstore/scheduled-backup/network-policy/database/role-secrets.sealed/r2-backup.sealed/kustomization 배치
   - role password `openssl rand -base64 24` 생성 → `kubeseal` seal (controller: `kube-system/sealed-secrets`)
   - R2 credential SealedSecret (namespace-scoped)
   - Cluster `spec.managed.roles` 에 `yq unique_by(.name)` idempotent 병합
6. ✅ **ArgoCD Application ignoreDifferences 자동 포함** (Phase 7 C, PR #14/#15 교훈): CNPG operator default 값 자동 채움 drift 무시 (`jsonPointers` + `jqPathExpressions` 13+ 경로)
7. ✅ Git commit + push + retry

### 검증 (merge 후)

```bash
NS=<app>
CLUSTER=<app>-pg

# 1. Cluster Ready
kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{"phase:"}{.status.phase}{" ready:"}{.status.readyInstances}/{.status.instances}{"\n"}'
# Expected: phase=Cluster in healthy state  ready=1/1

# 2. Database CR applied
kubectl -n "$NS" get database -o jsonpath='{range .items[*]}{.metadata.name}={.status.applied};{end}{"\n"}'
# Expected: <db>=true

# 3. Pod 2/2 Running (postgres + plugin init 완료)
kubectl -n "$NS" get pod -l cnpg.io/cluster="$CLUSTER"

# 4. ArgoCD Application Synced/Healthy
kubectl -n argocd get app "$NS" -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}'
# Expected: Synced/Healthy (ignoreDifferences 가 CNPG default drift 흡수)

# 5. psql 연결 검증
PASS=$(kubectl -n "$NS" get secret "${CLUSTER}-<role>-credentials" -o jsonpath='{.data.password}' | base64 -d)
kubectl -n "$NS" run psql-verify --rm -it --restart=Never --image=postgres:16-alpine \
  --env="PGPASSWORD=${PASS}" \
  --command -- psql "postgresql://<role>@${CLUSTER}-rw:5432/<db>?sslmode=require" -c "SELECT 1;"
```

### WAL archive + R2 객체 확인 (선택, 1분 이내)

```bash
# WAL segment 강제 switch (archive 유도)
PRIMARY=$(kubectl -n "$NS" get pod -l cnpg.io/cluster="$CLUSTER",cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$NS" exec "$PRIMARY" -c postgres -- psql -U postgres -c "SELECT pg_switch_wal();"

# R2 bucket 확인 (aws cli 필요, 임시 pod)
source _workspace/cnpg-migration/02_r2-credentials.txt
kubectl -n "$NS" run r2-check --rm -i --restart=Never --image=amazon/aws-cli:latest \
  --env="AWS_ACCESS_KEY_ID=${R2_ACCESS_KEY_ID}" \
  --env="AWS_SECRET_ACCESS_KEY=${R2_SECRET_ACCESS_KEY}" \
  --env="AWS_DEFAULT_REGION=auto" \
  --command -- aws --endpoint-url="${R2_ENDPOINT}" s3 ls "s3://homelab-db-backups/${NS}/${CLUSTER}/" --recursive | head
# Expected: wals/0000000100000000/000000010000000000000001.gz 이상
```

## 시나리오 A: 기존 앱에 DB 추가

기존 monorepo 앱 (`service-name` 구조) 에 DB 만 추가하려면:

```
Actions → Sync App Config → Run workflow  (미지원)
```

**현재는 자동화 미지원**. 수동 경로:
1. `manifests/apps/<app>/common/` 디렉토리 생성
2. [시나리오 C](#시나리오-c-수동-템플릿-복사) 의 템플릿 수동 복사
3. 앱 레포 `.app-config.yml` 에 `database.enabled: true` 추가 (향후 파서 확장 시 자동 처리)
4. PR → merge

## 시나리오 C: 수동 템플릿 복사 (긴급·참조)

`.github/templates/cnpg/*.yaml.tpl` 의 placeholder 를 sed 로 치환하여 `manifests/apps/<app>/common/` 에 배치.

### 단계

```bash
APP=<app>
ROLE=<role>         # 예: api, wiki
DB=<db>             # 예: api, wiki
R2_ACCOUNT_ID=$(grep R2_ACCOUNT_ID _workspace/cnpg-migration/02_r2-credentials.txt | cut -d= -f2 | tr -d '"')

mkdir -p "manifests/apps/$APP/common"
cd "manifests/apps/$APP/common"

# 1. namespace
cat > namespace.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${APP}
  labels:
    app.kubernetes.io/name: ${APP}
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
EOF

# 2. 템플릿 치환 (cluster, objectstore, scheduled-backup, network-policy, database, kustomization)
TEMPLATE_DIR="$OLDPWD/.github/templates/cnpg"
for tpl in cluster.yaml objectstore.yaml scheduled-backup.yaml network-policy.yaml kustomization.yaml; do
  sed \
    -e "s|__APP__|${APP}|g" \
    -e "s|__PG_IMAGE_TAG__|16.13-standard-trixie|g" \
    -e "s|__STORAGE__|10Gi|g" \
    -e "s|__R2_ACCOUNT_ID__|${R2_ACCOUNT_ID}|g" \
    "${TEMPLATE_DIR}/${tpl}.tpl" \
    > "${tpl}"
done

# 3. Database CR
sed \
  -e "s|__APP__|${APP}|g" \
  -e "s|__DB_NAME__|${DB}|g" \
  -e "s|__ROLE_NAME__|${ROLE}|g" \
  "${TEMPLATE_DIR}/database.yaml.tpl" \
  > database-shared.yaml

# 4. role SealedSecret
PASSWORD=$(openssl rand -base64 24)
awk -v pw="$PASSWORD" -v app="$APP" -v role="$ROLE" '
  {gsub(/__APP__/, app); gsub(/__ROLE_NAME__/, role); gsub(/__PASSWORD__/, pw); print}
' "${TEMPLATE_DIR}/role-secret.yaml.tpl" > /tmp/role.yaml
kubeseal --controller-namespace kube-system --controller-name sealed-secrets --format=yaml \
  < /tmp/role.yaml > role-secrets.sealed.yaml
rm /tmp/role.yaml

# 5. R2 credential SealedSecret
source $OLDPWD/_workspace/cnpg-migration/02_r2-credentials.txt
awk -v app="$APP" -v ak="$R2_ACCESS_KEY_ID" -v sk="$R2_SECRET_ACCESS_KEY" '
  {gsub(/__APP__/, app); gsub(/__R2_ACCESS_KEY_ID__/, ak); gsub(/__R2_SECRET_ACCESS_KEY__/, sk); print}
' "${TEMPLATE_DIR}/r2-backup-secret.yaml.tpl" > /tmp/r2.yaml
kubeseal --controller-namespace kube-system --controller-name sealed-secrets --format=yaml \
  < /tmp/r2.yaml > r2-backup.sealed.yaml
rm /tmp/r2.yaml

# 6. Cluster managed.roles 에 role 추가
ROLE_NAME="$ROLE" SECRET_NAME="${APP}-pg-${ROLE}-credentials" \
  yq eval -i '
    .spec.managed.roles = (
      (.spec.managed.roles // []) + [{
        "name": env(ROLE_NAME),
        "ensure": "present",
        "login": true,
        "passwordSecret": { "name": env(SECRET_NAME) }
      }]
      | unique_by(.name)
    )
  ' cluster.yaml
```

### 앱 레벨 kustomization + ArgoCD Application

```yaml
# manifests/apps/<app>/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - common
```

ArgoCD Application 에는 반드시 `ignoreDifferences` 블록 포함 (memory `project_cnpg_cluster_drift_pattern`):

```yaml
# argocd/applications/apps/<app>.yaml
spec:
  project: apps
  source:
    repoURL: https://github.com/ukkiee-dev/homelab.git
    path: manifests/apps/<app>
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: <app>
  syncPolicy:
    automated: { selfHeal: true, prune: true }
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
  ignoreDifferences:
    - group: postgresql.cnpg.io
      kind: Cluster
      name: <app>-pg
      namespace: <app>
      jsonPointers:
        - /spec/affinity
        - /spec/bootstrap
        - /spec/enablePDB
        - /spec/enableSuperuserAccess
        - /spec/failoverDelay
        - /spec/logLevel
        - /spec/maxSyncReplicas
        - /spec/minSyncReplicas
      jqPathExpressions:
        - .spec.managed.roles[].connectionLimit
        - .spec.managed.roles[].inherit
        - .spec.monitoring.customQueriesConfigMap
        - .spec.monitoring.disableDefaultQueries
        - .spec.plugins[].enabled
```

## apps AppProject destinations 갱신 (모든 시나리오 공통)

**⚠️ 중요 (Phase 6 PR #10/#14 교훈)**: 새 namespace 는 **2 곳** AppProject 에 등록:
- `manifests/infra/argocd/appproject-apps.yaml`: destinations 에 `<app>` 추가 (Application 소유)
- `manifests/infra/argocd/appproject-infra.yaml`: destinations 에 `<app>` 추가 (**scheduling app 이 ResourceQuota/LimitRange 를 이 namespace 에 배포** 하므로)

scheduling 에서도 `resourcequota-<app>.yaml` + `limitrange-<app>.yaml` 추가 필요 (`manifests/infra/scheduling/`).

## 트러블슈팅

### ArgoCD OutOfSync 지속 (15분+)

**원인**: CNPG operator 가 Cluster spec default 값 자동 채움 (drift 13+ 필드).

**확인**:
```bash
kubectl -n <app> get cluster <app>-pg -o json | jq '.metadata.managedFields'
# null 이면 client-side apply, managedFieldsManagers 무효
```

**해결**: ArgoCD Application 에 위 `ignoreDifferences` 블록 (jsonPointers + jqPathExpressions) 추가.

### scheduling Application SyncFailed

**증상**: "namespace `<app>` is not permitted in project 'infra'"

**원인**: `manifests/infra/argocd/appproject-infra.yaml` destinations 에 `<app>` 미등록.

**해결**: PR 로 destinations 추가 + merge + `argocd` Application hard-refresh.

### Cluster 생성 성공이나 psql 연결 실패

```bash
# sslmode 단계별 검증 (리뷰 M7 패턴)
kubectl -n <app> run psql-plain --rm -it --restart=Never --image=postgres:16-alpine \
  --env="PGPASSWORD=<pass>" \
  --command -- psql "postgresql://<role>@<app>-pg-rw:5432/<db>?sslmode=disable" -c "SELECT 1;"

# disable 성공 → require 실패면 TLS 계층 (operator CA 확인)
# disable 실패 → role password 또는 NetworkPolicy (K3s enforcement off 는 memory 참조)
```

### WAL archive 안 됨 (R2 객체 없음)

- Cluster `spec.plugins[]` 에 `barman-cloud.cloudnative-pg.io` + `isWALArchiver: true` 블록 있는지 확인
- ObjectStore CR + r2-backup Secret 존재 확인
- plugin Deployment Running: `kubectl -n cnpg-system get pod -l app.kubernetes.io/name=barman-cloud`

## 참고

- [Phase 6 pokopia-wiki 매니페스트](../../../manifests/apps/pokopia-wiki/common/) — 실 운영 예시 (이 Runbook 의 구조 기준)
- [cnpg-pitr-restore.md](./cnpg-pitr-restore.md) — PITR 복구 (동일 namespace)
- [cnpg-dr-new-namespace.md](./cnpg-dr-new-namespace.md) — DR replica
- [design v0.4 §6 시나리오](../../plans/2026-04-20-cloudnativepg-migration-design.md) — 공유 DB vs 분리 DB
- memory `project_cnpg_cluster_drift_pattern` — ignoreDifferences 설계 배경
- memory `feedback_cert_manager_cainjector_limits` — 인프라 의존성 주의
