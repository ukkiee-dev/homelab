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

> **2026-04-21 Phase 2-7 업데이트**: 입력 포맷 전면 변경. 이제 설정은 앱 레포의 `services/<svc>/.app-config.yml` 에서 읽어 homelab 에 전달. workflow_dispatch 입력은 `service-name` + `subdomain` 2개만.

### 사전 준비

1. 앱 GitHub 레포 생성: `ukkiee-dev/<app>` (app-starter 템플릿 기반)
2. 앱 레포 `pnpm service:add <svc>` 로 서비스 스캐폴딩 생성
3. `services/<svc>/.app-config.yml` 편집 (Phase 1+ 스키마):

   **owner 서비스 (신규 DB 생성)**:
   ```yaml
   # type 필드 없음 = HTTP service 기본 (web 또는 static — Dockerfile 이 결정)
   health: /health
   icon: mdi-book-open-variant
   description: <앱 설명>
   database:
     name: <db>         # PostgreSQL identifier (소문자·숫자·_, 63자 이하)
     storage: 10Gi      # 기본값, 상향만 가능 (local-path resize 미지원)
   ```

   **reference 서비스 (기존 owner DB 공유)**:
   ```yaml
   type: worker         # 또는 생략 (HTTP service)
   # health/icon/description 은 HTTP service 일 때만 사용
   database:
     ref: <owner-svc>   # 같은 project 내 owner 서비스 이름 (예: api)
   ```

4. 앱 레포의 `create-app.yml` 이 `read-config` job + `needs.read-config.outputs.config` → `config-yaml` 전달 패턴으로 구성되어 있는지 확인 (app-starter 기본 제공)

### DB 모드 결정 규칙 (D3 이분법)

| `.app-config.yml.database` | 판단 | 결과 |
|----------------------------|------|------|
| `{ name: foo }` | **owner** | CNPG Cluster + Database CR + role-secret 생성 |
| `{ ref: svc }` | **reference** | owner 의 role-secret 을 secretKeyRef 로 공유, 서비스 Deployment 에 PG env 5개 주입 |
| 블록 없음 | **none** | DB 매니페스트 생성 skip |
| `name` + `ref` 동시 | ❌ error | 상호배타 — Parse config step 에서 종료 |

### 실행

**앱 레포에서** workflow dispatch (homelab 이 아니라 **앱 레포**):

```
앱 레포 → Actions → Create App → Run workflow
  service-name:  api              # services/<name> 와 일치
  subdomain:     ""               # 비우면 <repo>-<service> 자동
```

- `read-config` job 이 `services/<svc>/.app-config.yml` 읽어 `config-yaml` 로 homelab `_create-app.yml` 에 전달
- homelab 쪽 Parse config step 이 `type`/`health`/`icon`/`description`/`database.{name|ref|storage}` 추출
- `database.name` 있으면 `Setup CNPG database (owner)` 실행
- `database.ref` 있으면 `Setup CNPG database (reference)` 실행

**주의사항**:
- `.app-config.yml` 없으면 `read-config` job 이 `::error::` + exit 1 — 먼저 생성 필수
- flat 앱은 현재 DB 미지원 (모노레포 구조 + `service-name` 필수). flat 앱에서 database 블록 쓰면 warning 후 skip
- `database.name` 과 `database.ref` 는 상호배타 — 둘 중 하나만

### 자동 처리 단계 (composite action 이 수행)

1. ✅ Caller (앱 레포) `read-config` job 이 `.app-config.yml` 읽어 `config-yaml` 로 전달
2. ✅ homelab `_create-app.yml` → `setup-app` composite 진입
3. ✅ **Parse config** step — yq 로 `type`/`health`/`icon`/`description`/`database.*` 추출 + db-mode 판단 (name/ref/none)
4. ✅ `apps.json` + Terraform DNS (worker 는 skip)
5. ✅ Cloudflare Tunnel ingress
6. ✅ 앱 Deployment / Service / IngressRoute / NetworkPolicy / GHCR pull secret
7. ✅ ArgoCD Application 생성 (`project: apps`)
8. ✅ **DB 매니페스트 생성** (db-mode 기반 분기):
   - **owner**: `common/` 에 cluster/objectstore/scheduled-backup/network-policy/database-shared/role-secrets.sealed/r2-backup.sealed/kustomization 배치. role password `openssl rand -base64 24` → `kubeseal` seal. Cluster `spec.managed.roles` 에 `yq unique_by(.name)` idempotent 병합
   - **reference**: owner 의 `common/database-shared.yaml` 에서 `.spec.name`/`.spec.owner` 추출 → reference 서비스 Deployment 에 PG 표준 env 5개 (`PGHOST`/`PGPORT`/`PGDATABASE`/`PGUSER`/`PGPASSWORD`) 주입. PGPASSWORD 는 owner 의 role-secret 을 `secretKeyRef` 로 재사용
9. ✅ **ArgoCD Application ignoreDifferences 자동 포함** (PR #14/#15 교훈): CNPG operator default 값 자동 채움 drift 무시 (`jsonPointers` + `jqPathExpressions` 13+ 경로)
10. ✅ AppProject destinations 자동 등록 (apps + infra)
11. ✅ Git commit + push + retry

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

> **2026-04-22 자동 reconcile**: app-starter `update-app.yml` (push 트리거) + homelab `_add-database.yml` 로 자동 처리. `.app-config.yml` 이 single source of truth — 수동 dispatch 불필요.
> 설계: [`plans/2026-04-21-add-database-workflow-design.md`](../../plans/2026-04-21-add-database-workflow-design.md)

기존 배포된 서비스에 DB 만 추가하려면 (teardown + create-app 재실행 필요 없음):

### 절차

1. 앱 레포 `services/<svc>/.app-config.yml` 에 `database` 블록 추가

   **owner (신규 DB 생성)**:
   ```yaml
   database:
     name: mydb          # PostgreSQL identifier (소문자·숫자·_)
     storage: 10Gi       # 선택 (기본 10Gi)
   ```

   **reference (기존 owner DB 공유, 같은 project 안)**:
   ```yaml
   database:
     ref: api            # 같은 project 내 owner 서비스 이름
   ```

2. **push 만 하면 자동 reconcile**.

   `update-app.yml` 이 `services/*/.app-config.yml` 변경을 감지 → `_add-database.yml` 호출 → DB 프로비저닝 + git push.

   수동 dispatch 가 필요한 경우 (예: 워크플로우 실패 후 재시도) 는 Actions UI → **Update App (reconcile)** → Run workflow (파라미터 없음 — `.app-config.yml` 현재 상태로 reconcile).

### 자동 처리

- Parse config → db-mode 판단 (owner/reference/none)
- Validate — service 디렉토리 존재 확인, 멱등성 체크 (이미 동일 구성이면 skip), immutability guard (name/ref 변경 시도 차단)
- owner: `setup-app/database@main` composite → Cluster + Database CR + role-secret 생성 → 루트 kustomization "common" 추가 → ArgoCD Application ignoreDifferences 추가
- reference: composite reference 분기 → 해당 서비스 Deployment env 에 PG 5개 (PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD) 주입 → ArgoCD 자동 롤링
- commit/push + Telegram 알림

### 멱등성

- 동일 config 로 재실행 → `::notice::이미 구성 완료` + git diff 비어있음 (안전)
- `database.name` 또는 `database.ref` 변경 시도 → `::error::` + 마이그레이션 가이드 출력 (차단)
- DB 이름 실제로 변경해야 하는 경우 → teardown → 새 `.app-config.yml` 로 create-app 재실행 (Runbook 하단 트러블슈팅 참조)

### 제약

- **모노레포 (service-name 필수)** 앱만 지원. flat 앱은 현재 DB 미지원
- reference 모드는 **owner 서비스가 이미 배포 완료** 상태여야 함 (common/database-shared.yaml 존재 전제)
- create-app 시점에 database 블록이 있었으면 이미 DB 가 있는 것이므로, 재push 시 reconcile 은 skip (멱등) — 후속 DB 추가용

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

### `.app-config.yml.database.name` 을 변경 push 했는데 반영 안 됨

**증상**: 앱 레포에 `database.name` 을 수정해서 push 했더니 `_sync-app-config.yml` 이 `::error::database.name 변경 감지: '<old>' → '<new>'` 로 실패.

**원인**: DB 이름 변경은 자동 마이그레이션 불가 — pg_dump/restore 가 필요. immutability guard (Phase 7 M1) 가 이를 방어.

**해결 절차**:
1. 기존 DB 데이터 보존 필요 시: `kubectl -n <app> exec <cluster>-1 -c postgres -- pg_dump <old-db>` → 덤프 파일 생성
2. homelab 에서 `gh workflow run teardown.yml -f app-name=<app>` 실행 (또는 service 모드로 부분 teardown)
3. 앱 레포 `.app-config.yml.database.name` 값 새 이름으로 유지한 채 create-app 재실행
4. 새 Cluster 준비되면 `psql ... < dump.sql` 로 복원

### reference 서비스 배포 시 `::error::reference 대상 서비스 디렉토리 없음`

**원인**: `.app-config.yml.database.ref` 에 owner 로 지정한 서비스가 아직 homelab 에 없음 (setup 순서 문제).

**해결**: owner 서비스를 먼저 `create-app.yml` 로 배포 → `manifests/apps/<app>/services/<owner>/` + `common/database-shared.yaml` 생성 확인 → 그 후 reference 서비스 배포.

## 참고

- [Phase 6 pokopia-wiki 매니페스트](../../../manifests/apps/pokopia-wiki/common/) — 실 운영 예시 (이 Runbook 의 구조 기준)
- [cnpg-pitr-restore.md](./cnpg-pitr-restore.md) — PITR 복구 (동일 namespace)
- [cnpg-dr-new-namespace.md](./cnpg-dr-new-namespace.md) — DR replica
- [design v0.4 §6 시나리오](../../plans/2026-04-20-cloudnativepg-migration-design.md) — 공유 DB vs 분리 DB
- memory `project_cnpg_cluster_drift_pattern` — ignoreDifferences 설계 배경
- memory `feedback_cert_manager_cainjector_limits` — 인프라 의존성 주의
