# 2026-04-21 세션 후속 작업

> **작성일**: 2026-04-21 (세션 종료 시점)
> **다음 세션 담당**: 이 문서를 먼저 읽고 상태를 재확인한 뒤 진행
> **관련 머지 PR**: homelab #26 / #27 / #28 / #29 / #30 / #31, app-starter #3 / #4 / #5

## 배경

2026-04-21 세션에서 두 가지 작업을 완료했다:

1. **app-starter 단순화 Phase 1-7** ([`2026-04-21-app-starter-simplification.md`](2026-04-21-app-starter-simplification.md)) — `.app-config.yml` single source of truth + deprecation-first 전략
2. **Add Database Workflow** ([`2026-04-21-add-database-workflow-design.md`](2026-04-21-add-database-workflow-design.md)) — 기존 서비스에 DB 추가 자동화

두 가지 후속 작업이 남았다.

---

## 후속 1. Phase 3b — deprecated inputs cleanup

### 목적

`_create-app.yml` (homelab) 과 `setup-app/action.yml` 에 남아 있는 deprecated inputs 제거. 입력 축소:
- `_create-app.yml`: 14 → 4 (`app-name`, `service-name`, `subdomain`, `config-yaml`)
- `setup-app/action.yml`: 11 → 4

제거 대상:
- `app-type`, `app-health`, `default-icon`
- `database-enabled`, `database-mode`, `database-name`, `database-ref`, `database-storage`
- `setup-app` 의 `type`, `health`, `icon`, `description`, `port` 등 deprecated inputs
- Parse config step 의 hybrid fallback 분기 (else 블록) 제거

### 전제조건 재확인 (중요)

Phase 3b 원본 전제조건:
- [x] app-starter `create-app.yml` config-yaml 전환 — **완료** (PR #4 머지)
- [x] test-web — **완료** (teardown + archive)
- [ ] pokopia-wiki caller config-yaml 전환 — **재확인 필요** (아래 참고)
- [ ] 다른 외부 caller 없음 확인

### pokopia-wiki 상태 (2026-04-21 세션 말 확인)

다음 상황을 **새 세션에서 먼저 재확인**할 것:

| 증거 | 결과 |
|------|------|
| `gh repo view ukkiee-dev/pokopia-wiki` | **404 Not Found** (레포 존재하지 않음) |
| `gh repo list ukkiee-dev` 에 pokopia-wiki | **없음** |
| `/Users/ukyi/workspace/pokopia-wiki/` 로컬 | **존재** (git config 의 remote 섹션 비어있음) |
| `manifests/apps/pokopia-wiki/` homelab 배포 상태 | **존재** (services/api/ 등) |
| `kubectl get app -n argocd pokopia-wiki` | **Synced/Healthy (확인 요)** |

**추정**: pokopia-wiki GitHub 레포는 private 이거나 삭제됨. 로컬 워크스페이스에 `create-app.yml` 이 있으나 push 가능한 remote 가 없어 workflow_dispatch 호출 자체가 불가능.

**다음 세션 검증 명령**:

```bash
# 1. 레포 실존 여부 재확인
gh repo view ukkiee-dev/pokopia-wiki 2>&1 | head -5

# 2. 조직 레벨 전체 조회 (private 포함)
gh repo list ukkiee-dev --limit 50 --json name,isPrivate,isArchived | yq '.' -p json

# 3. GitHub 에서 _create-app.yml 호출하는 워크플로우 전수 조사
gh search code 'ukkiee-dev/homelab/.github/workflows/_create-app.yml@main' --owner=ukkiee-dev --limit 20

# 4. 쿼리 결과에 app-starter / (삭제된 test-web 제외) 외에 다른 caller 가 있는지 확인
```

### 실행 계획

위 검증 후 pokopia-wiki 레포 상태에 따라:

#### Case A: pokopia-wiki GitHub 레포 실제로 없음 → **바로 Phase 3b 실행**

1. `gh search code` 로 homelab `_create-app.yml` 호출 caller 전수 조사
2. app-starter, test-web (archived) 외에 없으면 deprecation 제거 안전
3. 구현:
   - `.github/workflows/_create-app.yml`: deprecated inputs 제거, `config-yaml` 을 `required: true` 로 승격
   - `.github/actions/setup-app/action.yml`: deprecated inputs 제거, Parse config 의 fallback 분기 제거
   - 커밋 메시지: `refactor: _create-app.yml + setup-app deprecated inputs 제거 (Phase 3b)`

#### Case B: pokopia-wiki 레포 private 으로 존재 + 실제 사용 중

1. pokopia-wiki `create-app.yml` 업데이트 필요
2. 현재 `create-app.yml` 포맷 (로컬 확인):
   ```yaml
   with:
     app-name: ${{ github.event.repository.name }}
     subdomain: ${{ inputs.subdomain }}
     app-type: web                     # 제거
     app-health: /health               # 제거
     default-icon: mdi-application     # 제거
   ```
3. pokopia-wiki 를 app-starter 패턴으로 변환:
   - `read-config` job 추가 (root 또는 services/ 경로의 `.app-config.yml` cat)
   - 앱이 flat 구조인지 monorepo 인지 확인 (manifests 상 monorepo — `services/api/` 존재)
   - `.app-config.yml` 이 없으면 생성 (`health: /health`, `icon: mdi-application`, `description: ""`)
   - caller with 블록을 `{app-name, service-name, subdomain, config-yaml}` 로 축소
4. pokopia-wiki PR 머지 확인 후 → Case A 와 동일 Phase 3b 실행

### 성공 기준

- [x] `_create-app.yml` required 입력 = `[app-name, config-yaml]`, 선택 = `[service-name, subdomain]` (총 4개)
- [x] `setup-app/action.yml` inputs 에서 type/port/health/icon/description/database-* 모두 삭제됨
- [x] Parse config step 에 `if [ -z "$CONFIG_YAML" ]` 시 error + exit (fallback 없음)
- [x] 기존 배포된 앱 (adguard, homepage, uptime-kuma, postgresql, pokopia-wiki) 무영향 (caller 경로를 통해서만 setup-app 실행됨 — manifests 는 이미 생성된 상태)

### 결과 (2026-04-22 실행)

- **Case A 확정**: 2026-04-22 세션에서 재검증 — `ukkiee-dev/pokopia-wiki` GitHub 레포 404 (조직에 부재, private 포함 전수 조사 결과 `homelab + app-starter` 2개만 존재). `gh search code` 로도 `_create-app.yml` 호출 caller 추가 발견 없음. 로컬 `/Users/ukyi/workspace/pokopia-wiki/` 에는 `create-app.yml` 이 있으나 remote 미설정으로 호출 자체 불가 → Phase 3b 안전 실행.
- **제거된 입력 (11개)**: `_create-app.yml` 에서 `app-type`, `app-health`, `default-icon`, `database-enabled`, `database-mode`, `database-name`, `database-role`, `database-ref`, `database-storage`, `database-pg-image-tag` + "Fetch description from GitHub repo" step (setup-app 내부 Parse config 에서 동일 로직 수행).
- **setup-app 에서 추가 제거**: `type`, `port`, `health`, `icon`, `description`, `database-enabled`, `database-mode`, `database-name`, `database-role`, `database-ref`, `database-storage`, `database-pg-image-tag` + Parse config hybrid fallback (else 블록).
- **database composite 호출 변경**: `role-name: ""` (빈 값 → composite 가 `service-name|app-name` 기반 기본값 사용), `pg-image-tag` 생략 (composite default `16.13-standard-trixie` 사용, Renovate 추적).
- **검증**: `actionlint .github/workflows/_create-app.yml` → 0 errors, `yq` 로 inputs 수 일치 확인.

### 예상 소요

30분 (설계 확정, 변경 자체는 단순 제거)

---

## 후속 2. Add Database Workflow end-to-end 검증

### 목적

`_add-database.yml` 을 실제 클러스터에서 검증. 현재까지는 시뮬레이션 + 코드 리뷰만 통과.

### 시나리오 1: Reference 모드 (낮은 리스크, 우선 권장)

**전제**: pokopia-wiki 가 이미 owner DB (api 서비스) 보유 + homelab 에 배포 완료.

1. pokopia-wiki 로컬에 worker 서비스 추가:
   ```bash
   cd /Users/ukyi/workspace/pokopia-wiki
   # 모노레포 구조라면 이미 services/ 있음
   # 없다면 manual mkdir + scaffolding
   ```

2. `services/worker/.app-config.yml` 생성:
   ```yaml
   type: worker
   database:
     ref: api
   ```

3. worker 용 Dockerfile + package.json + 간단한 src (DB 쿼리만 하는 예제)

4. 코드 push → build.yml 이 GHCR 에 worker 이미지 push → homelab 에 worker manifests 자동 생성 (create-app 없이도 build.yml 이 update-manifest 호출할 것?)
   - 확인 필요: worker 처음 배포 시 create-app 거쳐야 하는지 또는 build.yml 만으로 가능한지
   - 만약 create-app 필요하면 먼저 `gh workflow run create-app.yml -f service-name=worker`

5. add-database dispatch:
   ```bash
   gh workflow run add-database.yml --repo ukkiee-dev/pokopia-wiki -f service-name=worker
   ```

6. 검증:
   ```bash
   # 6-1. worker Deployment env 에 PG 5개 주입됐는지
   kubectl -n pokopia-wiki get deploy worker -o jsonpath='{.spec.template.spec.containers[0].env}' | jq

   # 6-2. PGPASSWORD secretKeyRef 가 올바른 owner role-secret 참조
   # name 은 'pokopia-wiki-pg-api-credentials' 형식이어야 함

   # 6-3. Pod 재시작 후 Running
   kubectl -n pokopia-wiki get pod -l app.kubernetes.io/name=worker

   # 6-4. ArgoCD sync
   kubectl -n argocd get app pokopia-wiki -o jsonpath='{.status.sync.status}/{.status.health.status}'

   # 6-5. 실제 DB 쿼리 (worker pod 내부에서)
   POD=$(kubectl -n pokopia-wiki get pod -l app.kubernetes.io/name=worker -o jsonpath='{.items[0].metadata.name}')
   kubectl -n pokopia-wiki exec $POD -- psql -c "SELECT 1;"  # libpq 가 PG* env 자동 읽음
   ```

7. 멱등성 검증 — 같은 명령 재실행:
   ```bash
   gh workflow run add-database.yml --repo ukkiee-dev/pokopia-wiki -f service-name=worker
   # 워크플로우 로그에 "::notice::이미 reference 구성 완료" 확인
   # git log 에 새 commit 없음
   ```

### 시나리오 2: Owner 모드 (리스크 있음)

**주의**: 임시 테스트 레포에서만 수행. 실제 사용 앱에서 하지 말 것 (DB 매니페스트 잘못 만들면 복구 어려움).

1. `ukkiee-dev/test-db-add` 같은 임시 레포 생성 (app-starter 템플릿 기반)
2. `services/api/.app-config.yml`: DB 블록 없이 health 만 지정
3. create-app 실행 → 서비스 배포 (DB 없이)
4. `.app-config.yml.database: { name: testdb, storage: 10Gi }` 추가 + push
5. `gh workflow run add-database.yml -f service-name=api` dispatch
6. 검증:
   ```bash
   kubectl -n test-db-add get cluster test-db-add-pg
   kubectl -n test-db-add get database
   kubectl -n argocd get app test-db-add -o jsonpath='{.spec.ignoreDifferences}'
   ```
7. teardown: `gh workflow run teardown.yml --repo ukkiee-dev/homelab -f app-name=test-db-add`
8. 레포 archive 또는 삭제

### 실패 케이스 검증 (optional)

- 같은 config 재실행 → skip + notice
- `.app-config.yml.database.name` 변경 후 dispatch → error + 마이그레이션 가이드
- `.app-config.yml.database.ref` 변경 후 dispatch → error
- ref 가 존재하지 않는 서비스 이름 → setup-app/database validate-ref 에서 error
- service-name 이 잘못된 경우 → validate step 에서 "service 디렉토리 없음" error

### 예상 소요

reference 시나리오 1시간, owner 시나리오 추가 1시간 (teardown 포함).

### 실행 결과 (2026-04-22)

실제로는 **하이브리드 (owner + reference 한 레포)** 로 검증. pokopia-wiki GitHub 레포 부재(후속 1 Case A 참조) 때문에 시나리오 1 불가 → 시나리오 2 를 확장하여 monorepo owner + reference 를 한 임시 레포 (`ukkiee-dev/test-phase3b`) 에서 동시 검증.

#### 실행 흐름

1. `gh repo create ukkiee-dev/test-phase3b --template ukkiee-dev/app-starter --public --clone`
2. `pnpm run setup && pnpm install`
3. `pnpm service:add api --type web` + `services/api/.app-config.yml.database: { name: testdb, storage: 1Gi }`
4. `pnpm service:add worker --type worker` + `services/worker/.app-config.yml.database: { ref: api }`
5. push → build.yml 트리거 (이미지 없음 → notice)
6. `gh workflow run create-app.yml -f service-name=api -f subdomain=test-phase3b-api` → **실패 1 (kubeseal online 모드)**
7. **Phase 2: `fix(database): kubeseal offline 모드 전환` PR #34** 머지 후 재시도 → 성공
8. api Application Synced/Healthy, CNPG Cluster healthy=1/1, SealedSecret 2개 Synced=True
9. `gh workflow run create-app.yml -f service-name=worker` → 성공
10. worker Deployment env 5개 주입 확인 (매니페스트 + 클러스터 2중 일치)
11. `gh workflow run add-database.yml -f service-name=worker` 재실행 → `::notice::이미 reference 구성 완료` + homelab HEAD 불변 (멱등성)
12. `gh workflow run teardown.yml -f app-name=test-phase3b` → **실패 2 (ArgoCD REST API curl timeout)**
13. **Phase B: `fix(teardown): GitOps cascade 전환` PR #35** 머지 + `kubectl apply -f argocd/root.yaml` → Application cascade prune 완료
14. `gh repo archive ukkiee-dev/test-phase3b`

#### 검증 포인트 통과 증거

| 항목 | 결과 |
|------|------|
| 임시 레포 scaffolding | app-starter 템플릿 + pnpm service:add 로 api/worker 2개 서비스 monorepo 완성 |
| owner DB 배포 | CNPG Cluster `test-phase3b-pg` healthy=1/1, Database CR `testdb` applied=true, managed.roles=[api] |
| SealedSecret offline seal | `r2-pg-backup`, `test-phase3b-pg-api-credentials` 둘 다 Synced=True (kubeseal `--cert` offline 모드 실증) |
| reference PG env 주입 | 매니페스트 + 클러스터 모두 5개 env 정확 일치 (PGHOST/PGPORT/PGDATABASE=testdb/PGUSER=api/PGPASSWORD→owner secretKeyRef) |
| ArgoCD Application | `test-phase3b` Synced/Healthy |
| add-database 멱등성 | `##[notice]이미 reference 구성 완료 (ref=api) — skip` + homelab HEAD 변화 없음 |
| GitOps cascade teardown | ns + Application 모두 NotFound, root Synced/Healthy, DNS/Tunnel/GHCR 모두 cleanup |
| 레포 archive | isArchived=true |

#### 발견한 blocker + 구조적 fix

1. **kubeseal online 모드 → offline 전환** (PR #34, `fix(database): kubeseal offline 모드 전환`)
   - 설계 의도 (ARC in-cluster runner) 와 실행 환경 (GitHub-hosted runner) 괴리. `actions-runner-system` namespace 에 Pod/CRD 없어 ARC 미배포 상태로 밝혀짐.
   - 해결: controller public cert 를 `manifests/infra/sealed-secrets/controller-cert.pem` 커밋 + composite 의 `--controller-*` flag 를 `--cert <path>` 로 전환.

2. **teardown ArgoCD REST API → GitOps cascade** (PR #35, `fix(teardown): GitOps cascade 전환`)
   - `_teardown.yml` Step 3.5 가 `argo.ukkiee.dev` 외부 호출 → GHA runner 에서 curl timeout (exit 28).
   - 해결: `argocd/root.yaml` `prune: false → true` 로 전환 + Step 3.5 제거. git 삭제 → root sync prune → finalizer cascade.

#### 암묵지 (memory 로 기록 가치)

- **GHA runner 에서 homelab 클러스터 접근 불가** — kubeconfig 없음 + 외부 호스트(argo.ukkiee.dev) timeout. 앞으로 GHA 에서 클러스터 상태 변경이 필요한 모든 composite 는 offline 모드 (cert/manifest 기반) 또는 Git-driven GitOps 로 설계해야 한다.
- **ARC 는 설계만 되고 배포 안 된 상태** — `manifests/infra/arc-runners/` 의 values 에 placeholder 만 있음. helm install 이 필요하지만 GitHub App 설치 + SealedSecret 등 선행 작업 있어 현재 우선순위 낮음.
- **app-starter `pnpm service:add` 안내의 오류** — `gh workflow run _create-app.yml` 을 직접 호출하도록 안내하지만, 실제로는 `create-app.yml` (workflow_dispatch caller) 를 경유해야 `read-config` job 이 `.app-config.yml` 을 읽어 전달. app-starter 의 add-service 출력 스크립트 수정 필요 (후속 과제).

#### 후속 과제 (별도 세션 이관)

- **app-starter `add-service.ts` 출력 안내 수정** — `_create-app.yml` 직접 호출 → `create-app.yml` 경유로 정정
- **pokopia-wiki 레포 재생성 또는 정리** — GitHub 에 부재 상태이나 K8s 에 배포된 상태. 장기적으로 homelab 에서 pokopia-wiki manifests 를 teardown 하거나 새 레포로 복원 결정 필요
- **ARC 배포 재검토** — GitOps 가 대부분 해소했으니 ARC 는 우선순위 낮음. 다만 향후 in-cluster 빌드·테스트 필요 시 재평가

---

## 진행 권장 순서

1. **먼저 pokopia-wiki 레포 상태 재확인** (5분) — 위 "pokopia-wiki 상태" 섹션 명령 실행
2. **후속 2 시나리오 1 (reference 검증)** — 낮은 리스크로 먼저 검증
3. **후속 1 Phase 3b** — pokopia-wiki 상태에 따라 Case A 또는 Case B 분기
4. **후속 2 시나리오 2 (owner 검증)** — 선택 사항, 임시 레포 필요

## 참고 자료

- `docs/plans/2026-04-21-app-starter-simplification.md` — Phase 1-7 플랜 전체
- `docs/plans/2026-04-21-add-database-workflow-design.md` — add-database 설계
- `docs/plans/2026-04-21-add-database-workflow.md` — add-database 구현 플랜
- `docs/runbooks/postgresql/cnpg-new-project.md` — 시나리오 A 섹션 (add-database 사용법)
- memory `feedback_pr_workflow` — PR 워크플로우 규약
- memory `project_teardown_silent_failure` — teardown 잠재 이슈 패턴
