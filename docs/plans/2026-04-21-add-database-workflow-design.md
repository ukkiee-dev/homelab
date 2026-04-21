# Add Database Workflow 설계

> **작성일**: 2026-04-21
> **상태**: 설계 확정 (승인 완료), implementation plan 대기
> **전제**: app-starter 단순화 Phase 1-7 머지 완료 ([`2026-04-21-app-starter-simplification.md`](2026-04-21-app-starter-simplification.md))

## 배경

현재 앱 라이프사이클은 다음 상태다:

- **신규 앱 + DB 같이 생성**: `.app-config.yml` 에 `database.name` 또는 `database.ref` 선언 후 `create-app.yml` dispatch → 한 번에 DB 포함 생성 (Phase 2 + Phase 6).
- **기존 서비스에 DB 추가**: ❌ **미지원**. teardown 후 새 `.app-config.yml` 로 create-app 재실행해야 함 (data 손실 위험, 번거로움).

이 설계는 **기존 배포된 서비스에 DB 만 추가** 하는 별도 워크플로우를 제안한다.

---

## 결정 사항 (브레인스토밍 확정)

| ID | 선택지 | 결정 |
|----|--------|------|
| **B**  | 트리거 방식 (자동 push 감지 vs 수동 dispatch) | **B — 수동 dispatch**. 돌이키기 어려운 작업이라 명시적 승인 필요 |
| **B2** | 파일 구성 (update-app 확장 vs 신규 workflow) | **B2 — 신규 파일** (app-starter `add-database.yml` + homelab `_add-database.yml`). 책임 분리, create-app / teardown 와 네이밍 대칭 |
| **P1** | 입력 방식 | **P1 — `.app-config.yml` 기반** (config-yaml). single source of truth 유지, create-app 과 UX 일관 |
| **R2** | 지원 범위 | **R2 — owner + reference 둘 다**. Phase 6 composite 재사용 비용 거의 0 |
| **I1** | 멱등성 | **I1 — 완전 idempotent + name/ref 변경만 error**. 실수 방어 + immutability guard 와 정합 |
| **A**  | 코드 재사용 | **A — setup-app 의 DB step 들을 복제**. 공유 로직 3-4 step 뿐, composite 리팩터링은 over-engineering |

---

## 아키텍처

### 파일 구조

**앱 레포 (app-starter 기반) — `.github/workflows/add-database.yml`** (신규):

```yaml
name: Add Database

on:
  workflow_dispatch:
    inputs:
      service-name:
        description: "services/<name> — .app-config.yml.database 블록이 선언된 서비스"
        required: true
        type: string

permissions:
  contents: write

concurrency:
  group: homelab-terraform
  cancel-in-progress: false

jobs:
  read-config:
    if: github.repository != 'ukkiee-dev/app-starter'
    runs-on: ubuntu-latest
    outputs:
      config: ${{ steps.cat.outputs.config }}
    steps:
      - uses: actions/checkout@v4
      - id: cat
        env:
          SERVICE: ${{ inputs.service-name }}
        run: |
          # services/<svc>/.app-config.yml → GITHUB_OUTPUT 로 전달
          # (create-app.yml 과 완전 동일 패턴)

  add-db:
    needs: read-config
    if: github.repository != 'ukkiee-dev/app-starter'
    uses: ukkiee-dev/homelab/.github/workflows/_add-database.yml@main
    with:
      app-name:     ${{ github.event.repository.name }}
      service-name: ${{ inputs.service-name }}
      config-yaml:  ${{ needs.read-config.outputs.config }}
    secrets: inherit
```

**homelab — `.github/workflows/_add-database.yml`** (신규 reusable):

입력 4개 (app-name, service-name, config-yaml) + secrets (APP_ID, APP_PRIVATE_KEY, R2_*, TF_ACCOUNT_ID — CNPG composite 이 요구). Terraform/Cloudflare 시크릿은 불필요 (DNS/Tunnel 건드리지 않음).

### 실행 단계

```
1. Generate token
2. Checkout homelab
3. Install yq
4. Parse config        ← setup-app 의 Parse config 로직 복제 (A)
                         → outputs: type, db-mode, db-name, db-ref, db-storage
5. Validate:
   - service 디렉토리 존재 확인 (manifests/apps/<app>/services/<svc>/)
   - db-mode=none 이면 ::notice:: + 정상 종료 (exit 0)
   - 기존 common/database-shared.yaml 과 db-name 비교 → 불일치 시 ::error::
   - 기존 reference env 주입된 경우 current-ref 와 비교 → 불일치 시 ::error::
   - 현재 상태 = 목표 상태 이면 ::notice::이미 구성 완료 — skip (exit 0)
6. Setup CNPG database (owner)
   if: db-mode=owner → setup-app/database@main composite (mode=owner)
7. Setup CNPG database (reference)
   if: db-mode=reference → setup-app/database@main composite (mode=reference)
8. Update ArgoCD Application + root kustomization (owner 만)
   → setup-app/action.yml 의 동일 로직 복제:
     a) 루트 manifests/apps/<app>/kustomization.yaml 에 "common" 추가 (idempotent)
     b) ArgoCD Application 에 CNPG Cluster ignoreDifferences 추가 (idempotent)
9. Commit & Push (git-push-retry action 사용)
```

---

## 데이터 플로우

### owner 시나리오 (신규 DB 생성)

```
👤 services/api/.app-config.yml 에 database: { name: mydb, storage: 10Gi } 추가 + push
(build.yml 은 database 변경은 sync 대상 아니므로 자동 호출 X — 정상)
   ↓
👤 앱 레포 Actions → Add Database → Run workflow (service-name: api)
   ↓
app-starter add-database.yml (caller)
   ├─ read-config job: cat services/api/.app-config.yml → outputs.config
   └─ add-db job → homelab _add-database.yml (config-yaml 전달)
   ↓
homelab _add-database.yml
   ├─ Parse config → db-mode=owner, db-name=mydb, db-storage=10Gi
   ├─ Validate: common/database-shared.yaml 없음 → 신규 생성 OK
   ├─ setup-app/database@main (mode=owner) 호출
   │    → common/{cluster,database-shared,objectstore,scheduled-backup,
   │              network-policy,role-secrets.sealed,r2-backup.sealed,
   │              kustomization}.yaml 생성
   ├─ 루트 kustomization.yaml 에 "common" 추가
   ├─ ArgoCD Application 에 CNPG Cluster ignoreDifferences 추가
   └─ Commit & Push
   ↓
ArgoCD sync → CNPG Cluster 생성 + Database CR applied + role-secret materialized
```

### reference 시나리오 (기존 owner DB 공유)

```
전제: api 서비스 (owner) 가 이미 배포되어 common/database-shared.yaml 존재

👤 services/worker/.app-config.yml 에 database: { ref: api } 추가 + push
👤 Actions → Add Database → Run workflow (service-name: worker)
   ↓
homelab _add-database.yml
   ├─ Parse config → db-mode=reference, db-ref=api
   ├─ Validate: worker Deployment 의 env 에 PGHOST 없음 → 신규 주입 OK
   ├─ setup-app/database@main (mode=reference) 호출
   │    → worker Deployment env 에 PG 5개 주입 (PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD)
   │    → common/ 변경 없음 (owner 가 이미 만듦)
   └─ Commit & Push
   ↓
ArgoCD sync → worker Pod 자동 롤링 (env 변경 → spec hash 변경)
```

---

## 에러 처리 & 엣지 케이스

| 상황 | 동작 |
|------|------|
| `.app-config.yml` 에 database 블록 없음 | `::notice::database 블록 없음 — skip` + exit 0 |
| `database.name` + `database.ref` 동시 지정 | `::error::상호배타` + exit 1 (Parse config 재사용) |
| service 디렉토리 자체 없음 | `::error::service not found — create-app.yml 먼저 실행` + exit 1 |
| 이미 owner DB 존재 + 같은 name | `::notice::이미 구성 완료 — skip` + exit 0 (idempotent) |
| 이미 owner DB 존재 + 다른 name | `::error::database.name 변경 감지: <old> → <new>` + 마이그레이션 안내 + exit 1 |
| 이미 reference + 같은 ref | env 재주입 (unique_by 로 idempotent) — skip |
| 이미 reference + 다른 ref | `::error::database.ref 변경 감지: <old> → <new>` + exit 1 |
| reference 대상 owner 디렉토리 없음 | `::error::reference target not found` (Phase 6 validate-ref 재사용) + exit 1 |
| flat 앱 (service-name 비어있음) | `required: true` 로 input 레벨에서 차단. 만약 우회되면 `::error::` |
| 이미 호출된 직후 네트워크 오류 등 → 부분 생성 | git commit 은 성공한 리소스만 포함. 재실행 시 idempotent check 로 완성 |

---

## 테스트 전략

### 자동 검증

- **YAML 문법** — `yq eval '.'` 양쪽 파일
- **Parse config 시뮬레이션** — Phase 2 테스트 하네스 재사용 (config-yaml → outputs)
- **멱등성 mock**:
  - 동일 owner config 2회 호출 시 common/ 내용 불변, root kustomization 중복 없음, ArgoCD Application ignoreDifferences 배열 길이 유지
  - 동일 reference config 2회 호출 시 Deployment env 5개 유지 (unique_by)
- **에러 케이스 5건**:
  - database 블록 없음 → exit 0 + notice
  - name 변경 시도 → exit 1
  - ref 변경 시도 → exit 1
  - service 디렉토리 없음 → exit 1
  - reference target 없음 → exit 1 (validate-ref step)

### end-to-end 검증 (후속 session)

1. **Reference 시나리오**: pokopia-wiki 의 `services/api` 는 이미 owner → 새 worker 서비스를 add 하고 add-database 로 reference 구성 → env 주입 확인
2. **Owner 시나리오 (리스크 있음)**: 새 테스트 레포 생성 → api 서비스만 create-app → 그 후 add-database 로 DB 추가 → CNPG Cluster + Database CR 확인 → teardown

---

## 영향 평가

### 호환성
- 기존 caller (create-app 등) 영향 **0**. 신규 파일만 추가.
- `setup-app/database@main` composite 재사용 — 이미 Phase 6 에서 owner/reference 양쪽 구현됨.
- 기존 배포된 앱 (pokopia-wiki 등) 의 manifests 건들지 않음 — 해당 서비스에 dispatch 해야만 변경 발생.

### 안전장치
- `concurrency.group: homelab-terraform` — create-app 과 동일 그룹이라 동시 실행 차단 (terraform state lock 방어는 불필요하지만, git push 경쟁 방지)
- Immutability guard — Phase 7 `_sync-app-config.yml` 의 database drift 검증과 정합 (동일 에러 메시지 패턴)

### 리스크
| 리스크 | 완화 |
|--------|------|
| 부분 생성 후 실패 (common/ 일부만 생김) | 재실행 시 idempotent check 가 남은 것만 생성. `setup-app/database@main` composite 의 기존 idempotent 설계 (unique_by, if 체크) 활용 |
| Deployment 롤링 부담 (reference 추가 시 worker 재시작) | 정상 동작. ArgoCD 기본 rollingUpdate maxUnavailable=0, maxSurge=1 적용 |
| R2 backup prefix 충돌 (동일 app-name) | 불가능 — 이미 common/database-shared.yaml 있으면 idempotent skip |

---

## Out of Scope (후속)

- **DB 제거** (`remove-database.yml`): `.app-config.yml` 에서 database 블록 삭제 → common/ 제거 + env 제거. teardown 의 서비스 모드와 유사. 별도 설계 필요
- **DB 이름 변경 자동 마이그레이션**: pg_dump → restore 자동화. runbook 수준 (cnpg-new-project.md 이미 언급)
- **role-name 커스터마이즈**: 기본값 = service-name. `.app-config.yml.database.role` 필드 추가는 별도 기능 요청 시 고려

---

## 구현 PR 계획 (implementation plan 에서 확정)

| 순번 | 레포 | 내용 | 의존 |
|------|------|------|------|
| 1 | homelab | `_add-database.yml` 생성 + Parse config 복제 + setup-app/database 호출 + kustomization/Application 업데이트 로직 복제 | 없음 (기존 setup-app/database composite 재사용) |
| 2 | app-starter | `add-database.yml` 생성 (caller) | 1 |

---

## 성공 기준

- [ ] 신규 `.app-config.yml` 에 `database.name` 추가 후 dispatch → CNPG Cluster + Database CR + role-secret 생성, 기존 Deployment 무영향
- [ ] `.app-config.yml` 에 `database.ref` 추가 후 dispatch → 해당 서비스 Deployment env 에 PG 5개 주입, 자동 롤링
- [ ] 동일 config 로 재실행 시 `::notice::이미 구성 완료` + git diff 비어있음 (완전 idempotent)
- [ ] `database.name` 변경 시도 시 `::error::` + 마이그레이션 가이드 출력
- [ ] reference target 없으면 `::error::` + create-app 안내
- [ ] end-to-end: pokopia-wiki 에 새 worker 서비스 추가 + add-database 로 reference 구성 → 성공

---

## 관련 문서

- [`2026-04-21-app-starter-simplification.md`](2026-04-21-app-starter-simplification.md) — Phase 1-7 플랜 (이 설계의 전제)
- [`../runbooks/postgresql/cnpg-new-project.md`](../runbooks/postgresql/cnpg-new-project.md) — 신규 프로젝트 DB 추가 runbook
- `.github/actions/setup-app/database/action.yml` — Phase 6 에서 owner + reference 구현 완료한 composite (이 워크플로우가 재사용)
