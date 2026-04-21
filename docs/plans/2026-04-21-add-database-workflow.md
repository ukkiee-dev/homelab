# Add Database Workflow Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 기존 배포된 서비스에 `.app-config.yml.database` 블록만 추가하고 수동 dispatch → CNPG DB 매니페스트 자동 생성 (owner) 또는 reference 서비스 Deployment env 주입 (reference) 까지 수행하는 `add-database` 워크플로우 추가.

**Architecture:** homelab `.github/workflows/_add-database.yml` (reusable) + app-starter `.github/workflows/add-database.yml` (caller). caller 가 `.app-config.yml` 을 읽어 `config-yaml` 로 전달 → homelab 이 파싱 후 `setup-app/database@main` composite (Phase 6 구현) 호출 + `setup-app/action.yml` 의 공유 로직 (루트 kustomization "common" 추가, ArgoCD Application ignoreDifferences 추가) 복제.

**Tech Stack:** GitHub Actions (workflow_call + workflow_dispatch), yq v4, bash, `mikefarah/yq@v4`, `actions/create-github-app-token@v1`, 기존 composite `ukkiee-dev/homelab/.github/actions/setup-app/database@main`, `ukkiee-dev/homelab/.github/actions/git-push-retry`

**설계 문서:** [`2026-04-21-add-database-workflow-design.md`](2026-04-21-add-database-workflow-design.md) — 결정사항 (B2 + P1 + R2 + I1 + A), 데이터 플로우, 에러 케이스, 테스트 전략

---

## 0. 작업 전제조건

- [x] app-starter 단순화 Phase 1-7 머지 완료 (`setup-app/database@main` composite 에 owner + reference 분기 존재)
- [x] 설계 문서 커밋 완료 (`design/add-database-workflow` 브랜치, commit `7faaac8`)
- [x] 이 implementation plan 은 **현재 설계 브랜치에 계속** 추가 커밋 (플랜 + 구현을 같은 PR 에 묶음)

---

## Task 1: `_add-database.yml` 뼈대 생성

**목적**: workflow_call inputs 정의 + 기본 step 4개 (token, checkout, yq 설치, 빈 skeleton).

**Files:**
- Create: `/Users/ukyi/homelab/.github/workflows/_add-database.yml`

**Step 1.1: 파일 생성 (뼈대)**

```yaml
name: Add Database (Reusable)

on:
  workflow_call:
    inputs:
      app-name:
        required: true
        type: string
      service-name:
        description: "모노레포 서비스 이름 (services/<name>)"
        required: true
        type: string
      config-yaml:
        description: ".app-config.yml 내용 (caller 가 읽어 전달)"
        required: true
        type: string
    secrets:
      APP_ID: { required: true }
      APP_PRIVATE_KEY: { required: true }
      TF_ACCOUNT_ID: { required: true }
      R2_ACCESS_KEY_ID: { required: true }
      R2_SECRET_ACCESS_KEY: { required: true }
      TELEGRAM_BOT_TOKEN: { required: false }
      TELEGRAM_CHAT_ID: { required: false }

jobs:
  add-database:
    runs-on: ubuntu-latest
    # NOTE: caller workflow 에 permissions 상속. 이 파일에는 permissions 블록 금지
    #       (feedback_workflow_call_permissions.md — reusable startup_failure 방지).
    steps:
      - name: Generate token
        id: app-token
        uses: actions/create-github-app-token@v1
        with:
          app-id: ${{ secrets.APP_ID }}
          private-key: ${{ secrets.APP_PRIVATE_KEY }}
          owner: ukkiee-dev
          repositories: homelab

      - name: Checkout homelab
        uses: actions/checkout@v4
        with:
          repository: ukkiee-dev/homelab
          token: ${{ steps.app-token.outputs.token }}

      - name: Install yq
        uses: mikefarah/yq@v4
```

**Step 1.2: YAML 문법 검증**

Run: `yq eval '.' .github/workflows/_add-database.yml > /dev/null && echo "✅ valid"`
Expected: `✅ valid`

**Step 1.3: Commit**

```bash
git add .github/workflows/_add-database.yml
git commit -m "feat(workflow): _add-database.yml 뼈대 추가 (inputs + checkout + yq)"
```

---

## Task 2: Parse config step 복제

**목적**: `setup-app/action.yml` 의 `Parse config` step 로직을 이 workflow 에 복제. outputs 로 `type/db-mode/db-name/db-ref/db-storage` 방출.

**Files:**
- Modify: `.github/workflows/_add-database.yml`

**Step 2.1: Install yq 뒤에 Parse config step 추가**

`- name: Install yq` 블록 뒤에 삽입:

```yaml
      # Phase 2 의 Parse config 로직 복제 (config-yaml 만 지원 — fallback 불필요).
      # 이 workflow 는 Phase 2+ 전제라 deprecated inputs 경로 없음.
      - name: Parse config
        id: config
        shell: bash
        env:
          APP_NAME: ${{ inputs.app-name }}
          CONFIG_YAML: ${{ inputs.config-yaml }}
        run: |
          set -euo pipefail

          if [ -z "$CONFIG_YAML" ]; then
            echo "::error::config-yaml 비어있음 — caller 가 .app-config.yml 을 전달하지 않았습니다"
            exit 1
          fi

          CONFIG_FILE=$(mktemp)
          printf '%s\n' "$CONFIG_YAML" > "$CONFIG_FILE"

          RAW_TYPE=$(yq '.type // ""' "$CONFIG_FILE")
          DB_NAME=$(yq '.database.name // ""' "$CONFIG_FILE")
          DB_REF=$(yq '.database.ref // ""' "$CONFIG_FILE")
          DB_STORAGE=$(yq '.database.storage // "10Gi"' "$CONFIG_FILE")
          rm -f "$CONFIG_FILE"

          # type 검증 (setup-app 과 동일)
          case "$RAW_TYPE" in
            ""|worker) TYPE="${RAW_TYPE:-http}" ;;
            web|static)
              echo "::warning::type: $RAW_TYPE 은 deprecated"
              TYPE=http
              ;;
            *)
              echo "::error::invalid type: $RAW_TYPE"
              exit 1
              ;;
          esac
          [ "$TYPE" = "" ] && TYPE=http

          # DB 모드 결정
          if [ -n "$DB_NAME" ] && [ -n "$DB_REF" ]; then
            echo "::error::database.name 과 database.ref 는 상호 배타"
            exit 1
          elif [ -n "$DB_NAME" ]; then
            DB_MODE=owner
          elif [ -n "$DB_REF" ]; then
            DB_MODE=reference
          else
            DB_MODE=none
          fi

          {
            echo "type=$TYPE"
            echo "db-mode=$DB_MODE"
            echo "db-name=$DB_NAME"
            echo "db-ref=$DB_REF"
            echo "db-storage=$DB_STORAGE"
          } >> "$GITHUB_OUTPUT"

          echo "── Parse config 결과 ──────────────"
          echo "  type=$TYPE db-mode=$DB_MODE"
          if [ "$DB_MODE" != "none" ]; then
            echo "  db-name=$DB_NAME db-ref=$DB_REF db-storage=$DB_STORAGE"
          fi
```

**Step 2.2: 파싱 시뮬레이션 — owner, reference, none, error 4 케이스**

```bash
SCRIPT=$(yq '.jobs.add-database.steps[] | select(.id == "config") | .run' .github/workflows/_add-database.yml)

test_case() {
  local label="$1"; local yaml="$2"; local expected_rc="$3"
  local out; out=$(mktemp); local rc=0
  env -i PATH="$PATH" HOME="$HOME" \
    APP_NAME="demo" CONFIG_YAML="$yaml" GITHUB_OUTPUT="$out" \
    bash -c "$SCRIPT" > /dev/null 2>&1 || rc=$?
  echo "  rc=$rc  [$label]  (expected=$expected_rc) $([ "$rc" = "$expected_rc" ] && echo ✅ || echo ❌)"
  cat "$out" | sed 's/^/    /'
  rm -f "$out"
}

test_case "owner" "$(printf 'database:\n  name: mydb\n  storage: 20Gi\n')" 0
test_case "reference" "$(printf 'type: worker\ndatabase:\n  ref: api\n')" 0
test_case "none" "$(printf 'health: /health\n')" 0
test_case "error: name+ref" "$(printf 'database:\n  name: x\n  ref: y\n')" 1
test_case "error: empty config-yaml" "" 1
```

Expected: 5건 모두 rc 일치, outputs 내용 정확.

**Step 2.3: Commit**

```bash
git add .github/workflows/_add-database.yml
git commit -m "feat(workflow/add-db): Parse config step 추가 (Phase 2 로직 복제)"
```

---

## Task 3: Validate step (멱등성 + immutability 검증)

**목적**: idempotency check, service 디렉토리 존재 확인, 기존 DB 와 drift 감지.

**Files:**
- Modify: `.github/workflows/_add-database.yml`

**Step 3.1: Parse config 뒤에 Validate step 추가**

```yaml
      # I1: 완전 idempotent + name/ref 변경만 error.
      # 추가로 service 디렉토리 존재 확인 + db-mode=none 조기 종료.
      - name: Validate (idempotency + immutability)
        id: validate
        shell: bash
        env:
          APP: ${{ inputs.app-name }}
          SERVICE: ${{ inputs.service-name }}
          DB_MODE: ${{ steps.config.outputs.db-mode }}
          DB_NAME: ${{ steps.config.outputs.db-name }}
          DB_REF: ${{ steps.config.outputs.db-ref }}
        run: |
          set -euo pipefail

          # 1. db-mode=none 이면 조기 종료 (정상)
          if [ "$DB_MODE" = "none" ]; then
            echo "::notice::.app-config.yml 에 database 블록 없음 — skip"
            echo "skip=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          # 2. service 디렉토리 존재 확인
          SVC_DIR="manifests/apps/${APP}/services/${SERVICE}"
          if [ ! -d "$SVC_DIR" ]; then
            echo "::error::service 디렉토리 없음: $SVC_DIR"
            echo "::error::먼저 create-app.yml 로 서비스를 생성하세요"
            exit 1
          fi

          # 3. 기존 DB 설정 조회
          SHARED="manifests/apps/${APP}/common/database-shared.yaml"
          CURRENT_DB=""
          if [ -f "$SHARED" ]; then
            CURRENT_DB=$(yq '.spec.name // ""' "$SHARED")
          fi

          # 4. 기존 reference env 조회 (Deployment env 에 PGDATABASE 값 = owner-db, PGUSER 값 = owner-role)
          DEPLOYMENT="$SVC_DIR/deployment.yaml"
          CURRENT_PGUSER=""
          if [ -f "$DEPLOYMENT" ]; then
            CURRENT_PGUSER=$(yq '.spec.template.spec.containers[0].env // [] | map(select(.name == "PGUSER")) | .[0].value // ""' "$DEPLOYMENT")
          fi

          # 5. owner 모드 검증
          if [ "$DB_MODE" = "owner" ]; then
            if [ -n "$CURRENT_DB" ] && [ "$CURRENT_DB" != "$DB_NAME" ]; then
              echo "::error::database.name 변경 감지: '$CURRENT_DB' → '$DB_NAME'"
              echo "::error::DB 이름 변경은 자동 마이그레이션 불가. Runbook 참조:"
              echo "::error::  docs/runbooks/postgresql/cnpg-new-project.md"
              exit 1
            fi
            if [ -n "$CURRENT_DB" ] && [ "$CURRENT_DB" = "$DB_NAME" ]; then
              echo "::notice::이미 owner DB 구성 완료 (name=$DB_NAME) — skip"
              echo "skip=true" >> "$GITHUB_OUTPUT"
              exit 0
            fi
            echo "skip=false" >> "$GITHUB_OUTPUT"
            echo "✅ owner 모드 신규 구성 대상 (db-name=$DB_NAME)"
          fi

          # 6. reference 모드 검증
          if [ "$DB_MODE" = "reference" ]; then
            # reference target (owner 서비스) 존재 확인은 setup-app/database 의 validate-ref step 이 처리
            if [ -n "$CURRENT_PGUSER" ] && [ "$CURRENT_PGUSER" != "$DB_REF" ]; then
              echo "::error::database.ref 변경 감지: '$CURRENT_PGUSER' → '$DB_REF'"
              echo "::error::reference 변경은 teardown 후 재구성 필요"
              exit 1
            fi
            if [ -n "$CURRENT_PGUSER" ] && [ "$CURRENT_PGUSER" = "$DB_REF" ]; then
              echo "::notice::이미 reference 구성 완료 (ref=$DB_REF) — skip"
              echo "skip=true" >> "$GITHUB_OUTPUT"
              exit 0
            fi
            echo "skip=false" >> "$GITHUB_OUTPUT"
            echo "✅ reference 모드 신규 구성 대상 (db-ref=$DB_REF)"
          fi
```

**Step 3.2: 8 케이스 시뮬레이션**

```bash
VALIDATE=$(yq '.jobs.add-database.steps[] | select(.id == "validate") | .run' .github/workflows/_add-database.yml)

MOCK=$(mktemp -d)
mkdir -p "$MOCK/manifests/apps/demo/common" \
         "$MOCK/manifests/apps/demo/services/api" \
         "$MOCK/manifests/apps/demo/services/worker"

run() {
  local name="$1"; shift
  local out=$(mktemp); local rc=0
  (cd "$MOCK" && env -i PATH="$PATH" HOME="$HOME" "$@" GITHUB_OUTPUT="$out" bash -c "$VALIDATE" 2>&1) | sed 's/^/  /' || true
  rc=${PIPESTATUS[0]:-0}
  echo "  rc=$rc  [$name]"
  [ -s "$out" ] && sed 's/^/    out: /' "$out"
  echo ""
  rm -f "$out"
}

run "db-mode=none (skip)" APP=demo SERVICE=api DB_MODE=none
run "service 디렉토리 없음" APP=demo SERVICE=missing DB_MODE=owner DB_NAME=mydb
run "owner 신규" APP=demo SERVICE=api DB_MODE=owner DB_NAME=mydb

cat > "$MOCK/manifests/apps/demo/common/database-shared.yaml" <<EOF
spec: { name: mydb, owner: api }
EOF
run "owner idempotent (같은 name)" APP=demo SERVICE=api DB_MODE=owner DB_NAME=mydb
run "owner name 변경 시도 (error)" APP=demo SERVICE=api DB_MODE=owner DB_NAME=newdb

cat > "$MOCK/manifests/apps/demo/services/worker/deployment.yaml" <<EOF
spec:
  template:
    spec:
      containers:
        - env:
            - { name: PGUSER, value: api }
EOF
run "reference 신규 (env 없는 service)" APP=demo SERVICE=api DB_MODE=reference DB_REF=api
run "reference idempotent (같은 ref)" APP=demo SERVICE=worker DB_MODE=reference DB_REF=api
run "reference ref 변경 시도 (error)" APP=demo SERVICE=worker DB_MODE=reference DB_REF=different

rm -rf "$MOCK"
```

Expected:
- none skip, owner idempotent, reference idempotent, reference 신규: rc=0 + `skip=true` 또는 `skip=false`
- 디렉토리 없음, owner name 변경, reference ref 변경: rc=1

**Step 3.3: Commit**

```bash
git add .github/workflows/_add-database.yml
git commit -m "feat(workflow/add-db): Validate step — idempotency + immutability guard"
```

---

## Task 4: `setup-app/database@main` composite 호출 (owner + reference)

**목적**: Phase 6 에서 만든 composite 을 그대로 호출. skip=true 이면 전체 job 종료.

**Files:**
- Modify: `.github/workflows/_add-database.yml`

**Step 4.1: Validate 뒤에 owner/reference 호출 step 추가**

```yaml
      # db-mode=owner → Cluster + Database CR + role-secret 생성
      - name: Setup CNPG database (owner)
        if: steps.validate.outputs.skip != 'true' && steps.config.outputs.db-mode == 'owner'
        uses: ukkiee-dev/homelab/.github/actions/setup-app/database@main
        with:
          app-name:             ${{ inputs.app-name }}
          service-name:         ${{ inputs.service-name }}
          mode:                 owner
          db-name:              ${{ steps.config.outputs.db-name }}
          ref-db:               ""
          role-name:            ""
          storage:              ${{ steps.config.outputs.db-storage }}
          r2-account-id:        ${{ secrets.TF_ACCOUNT_ID }}
          r2-access-key-id:     ${{ secrets.R2_ACCESS_KEY_ID }}
          r2-secret-access-key: ${{ secrets.R2_SECRET_ACCESS_KEY }}
          homelab-path:         "."

      # db-mode=reference → 서비스 Deployment env 에 PG 5개 주입
      - name: Setup CNPG database (reference)
        if: steps.validate.outputs.skip != 'true' && steps.config.outputs.db-mode == 'reference'
        uses: ukkiee-dev/homelab/.github/actions/setup-app/database@main
        with:
          app-name:             ${{ inputs.app-name }}
          service-name:         ${{ inputs.service-name }}
          mode:                 reference
          db-name:              ""
          ref-db:               ${{ steps.config.outputs.db-ref }}
          role-name:            ""
          r2-account-id:        ${{ secrets.TF_ACCOUNT_ID }}
          r2-access-key-id:     ${{ secrets.R2_ACCESS_KEY_ID }}
          r2-secret-access-key: ${{ secrets.R2_SECRET_ACCESS_KEY }}
          homelab-path:         "."
```

**Step 4.2: YAML 문법 검증 + step 개수 확인**

```bash
yq eval '.' .github/workflows/_add-database.yml > /dev/null && echo "✅ valid"
echo "step 목록:"
yq '.jobs.add-database.steps[] | .name // .id' .github/workflows/_add-database.yml
```

Expected: 7 step (Generate token, Checkout, yq, config, validate, Setup owner, Setup reference).

**Step 4.3: Commit**

```bash
git add .github/workflows/_add-database.yml
git commit -m "feat(workflow/add-db): setup-app/database composite 호출 (owner + reference)"
```

---

## Task 5: 루트 kustomization + ArgoCD Application 업데이트 (owner 모드 only)

**목적**: setup-app/action.yml 의 "Update ArgoCD Application for DB common/ + ignoreDifferences" step 을 복제. owner 모드에서만 실행.

**Files:**
- Modify: `.github/workflows/_add-database.yml`

**Step 5.1: reference step 뒤에 owner post-processing step 추가**

```yaml
      # owner 생성 후: 루트 kustomization 에 "common" 추가 + ArgoCD Application 에
      # CNPG Cluster ignoreDifferences 추가. setup-app/action.yml 과 동일 로직.
      - name: Update ArgoCD Application for DB (owner post-processing)
        if: steps.validate.outputs.skip != 'true' && steps.config.outputs.db-mode == 'owner'
        shell: bash
        env:
          APP: ${{ inputs.app-name }}
        run: |
          set -euo pipefail

          # 1. 루트 kustomization 에 common/ 추가 (idempotent)
          ROOT_KUST="manifests/apps/${APP}/kustomization.yaml"
          if [ -f "$ROOT_KUST" ]; then
            if ! yq eval '.resources[]' "$ROOT_KUST" | grep -qx "common"; then
              yq eval -i '.resources = (.resources + ["common"] | unique)' "$ROOT_KUST"
              echo "✅ 루트 kustomization 에 common/ 추가"
            else
              echo "⏭️  루트 kustomization 에 common/ 이미 존재"
            fi
          fi

          # 2. ArgoCD Application 에 CNPG Cluster ignoreDifferences 추가 (idempotent via unique_by)
          APP_FILE="argocd/applications/apps/${APP}.yaml"
          if [ -f "$APP_FILE" ]; then
            CLUSTER_NAME="${APP}-pg"
            APP_NS="$APP" CLUSTER_NAME="$CLUSTER_NAME" yq eval -i '
              .spec.ignoreDifferences = ((.spec.ignoreDifferences // []) + [{
                "group": "postgresql.cnpg.io",
                "kind": "Cluster",
                "name": env(CLUSTER_NAME),
                "namespace": env(APP_NS),
                "jsonPointers": [
                  "/spec/affinity",
                  "/spec/bootstrap",
                  "/spec/enablePDB",
                  "/spec/enableSuperuserAccess",
                  "/spec/failoverDelay",
                  "/spec/logLevel",
                  "/spec/maxSyncReplicas",
                  "/spec/minSyncReplicas"
                ],
                "jqPathExpressions": [
                  ".spec.managed.roles[].connectionLimit",
                  ".spec.managed.roles[].inherit",
                  ".spec.monitoring.customQueriesConfigMap",
                  ".spec.monitoring.disableDefaultQueries",
                  ".spec.plugins[].enabled"
                ]
              }] | unique_by(.kind + "/" + .name))
            ' "$APP_FILE"
            echo "✅ ArgoCD Application 에 CNPG Cluster ignoreDifferences 추가"
          fi
```

**Step 5.2: idempotent 멱등성 mock 검증**

```bash
MOCK=$(mktemp -d)
cd "$MOCK"
mkdir -p manifests/apps/demo argocd/applications/apps

cat > manifests/apps/demo/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - services/api
EOF

cat > argocd/applications/apps/demo.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: demo }
spec: { project: apps }
EOF

SCRIPT=$(yq '.jobs.add-database.steps[] | select(.name | test("owner post-processing")) | .run' ../homelab/.github/workflows/_add-database.yml 2>/dev/null)

# 1차 실행
APP=demo bash -c "$SCRIPT"
echo "--- 1차 후 kustomization ---"
cat manifests/apps/demo/kustomization.yaml
echo "--- 1차 후 ignoreDifferences 길이 ---"
yq '.spec.ignoreDifferences | length' argocd/applications/apps/demo.yaml

# 2차 실행 (재실행 idempotent 확인)
APP=demo bash -c "$SCRIPT"
echo "--- 2차 후 common/ 중복 ---"
yq '.resources[]' manifests/apps/demo/kustomization.yaml | grep -c common
echo "--- 2차 후 ignoreDifferences 길이 ---"
yq '.spec.ignoreDifferences | length' argocd/applications/apps/demo.yaml

cd - > /dev/null
rm -rf "$MOCK"
```

Expected: 1차에 common 추가 + ignoreDifferences=1. 2차 실행 후에도 common 1개, ignoreDifferences=1 (unique_by).

**Step 5.3: Commit**

```bash
git add .github/workflows/_add-database.yml
git commit -m "feat(workflow/add-db): owner post-processing (root kustomization + ignoreDifferences)"
```

---

## Task 6: Commit & Push + notification

**Files:**
- Modify: `.github/workflows/_add-database.yml`

**Step 6.1: Owner post-processing 뒤에 Commit & Push step 추가**

```yaml
      - name: Commit & Push
        if: steps.validate.outputs.skip != 'true'
        shell: bash
        env:
          APP: ${{ inputs.app-name }}
          SERVICE: ${{ inputs.service-name }}
          DB_MODE: ${{ steps.config.outputs.db-mode }}
          DB_NAME: ${{ steps.config.outputs.db-name }}
          DB_REF: ${{ steps.config.outputs.db-ref }}
        run: |
          set -euo pipefail
          git config user.email "deploy-bot@users.noreply.github.com"
          git config user.name "deploy-bot[bot]"

          git add manifests/ argocd/

          if git diff --staged --quiet; then
            echo "변경사항 없음 — 이미 반영됨, 커밋 skip"
            exit 0
          fi

          if [ "$DB_MODE" = "owner" ]; then
            git commit -m "feat(db): add owner DB '${DB_NAME}' to ${APP}/${SERVICE}"
          else
            git commit -m "feat(db): add reference to '${DB_REF}' in ${APP}/${SERVICE}"
          fi

      - name: Push with retry
        if: steps.validate.outputs.skip != 'true'
        uses: ./.github/actions/git-push-retry

      # Telegram 알림 (선택)
      - name: Notify success (Telegram)
        if: success() && steps.validate.outputs.skip != 'true'
        env:
          TG_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TG_CHAT: ${{ secrets.TELEGRAM_CHAT_ID }}
          APP: ${{ inputs.app-name }}
          SERVICE: ${{ inputs.service-name }}
          DB_MODE: ${{ steps.config.outputs.db-mode }}
        run: |
          if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; then exit 0; fi
          curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT}" \
            -d text="🗄️ DB 추가 완료 (${DB_MODE}): ${APP}/${SERVICE}"
```

**Step 6.2: 최종 YAML 유효성 + step 개수**

```bash
yq eval '.' .github/workflows/_add-database.yml > /dev/null && echo "✅ valid"
echo "step 수: $(yq '.jobs.add-database.steps | length' .github/workflows/_add-database.yml)"
echo "step 목록:"
yq '.jobs.add-database.steps[] | .name // .id' .github/workflows/_add-database.yml
```

Expected: 10 step (Generate token, Checkout, yq, config, validate, owner, reference, owner post-processing, Commit & Push, Push with retry, Telegram).

**Step 6.3: Commit**

```bash
git add .github/workflows/_add-database.yml
git commit -m "feat(workflow/add-db): Commit & Push + Telegram 알림"
```

---

## Task 7: homelab PR 생성 + 머지

**Step 7.1: push + PR**

```bash
git push -u origin design/add-database-workflow
gh pr create --base main --title "feat(workflow): _add-database.yml 추가 (기존 서비스에 DB 추가)" --body "$(cat <<'EOF'
## 변경 사항

[Design doc](docs/plans/2026-04-21-add-database-workflow-design.md) 의 B2+P1+R2+I1+A 결정 구현.

기존 배포된 서비스에 `.app-config.yml.database` 블록만 추가한 뒤 수동 dispatch 로 CNPG DB 생성 (owner) 또는 env 주입 (reference) 까지 자동화.

## 추가 사항

### 새 파일
- `.github/workflows/_add-database.yml` — reusable workflow (app-starter caller 가 호출 예정)

### 동작
- **owner 모드** (`.app-config.yml.database.name` 지정): `setup-app/database@main` 호출 → Cluster + Database CR + role-secret 생성 → 루트 kustomization 에 common/ 추가 → ArgoCD Application 에 ignoreDifferences 추가 → commit/push
- **reference 모드** (`.app-config.yml.database.ref` 지정): `setup-app/database@main` reference 분기 호출 → 서비스 Deployment env 에 PG 5개 주입 → commit/push
- **멱등성 (I1)**: 이미 동일 구성이면 skip, name/ref 변경 시도는 error
- **설계 문서**: `docs/plans/2026-04-21-add-database-workflow-design.md` 동반 커밋

## 테스트
- [x] Parse config 시뮬레이션 5 케이스 (owner/reference/none/name+ref/empty) 통과
- [x] Validate 시뮬레이션 8 케이스 통과
- [x] Owner post-processing idempotent mock 검증 (재실행 후 common/ 1개, ignoreDifferences 1개)
- [ ] end-to-end 는 app-starter caller 추가 후 pokopia-wiki 또는 테스트 레포로 검증

## 후속
- app-starter PR: `add-database.yml` caller 추가
EOF
)"
```

**Step 7.2: 머지 (CLEAN + MERGEABLE 확인 후)**

```bash
gh pr view --json mergeable,mergeStateStatus
gh pr merge --squash --delete-branch
git checkout main && git pull origin main
```

---

## Task 8: app-starter `add-database.yml` caller 추가

**Files:**
- Create: `/Users/ukyi/workspace/app-starter/.github/workflows/add-database.yml`

**Step 8.1: app-starter 브랜치 생성**

```bash
cd /Users/ukyi/workspace/app-starter
git checkout main && git pull origin main
git checkout -b feat/add-database-caller
```

**Step 8.2: `add-database.yml` 작성**

`/Users/ukyi/workspace/app-starter/.github/workflows/add-database.yml`:

```yaml
name: Add Database

# 기존 배포된 서비스에 .app-config.yml.database 블록을 추가했을 때 수동 dispatch.
# CNPG Cluster + Database CR (owner) 또는 Deployment env 주입 (reference) 까지 자동.
#
# 전제:
#   1. create-app.yml 로 서비스가 이미 homelab 에 배포되어 있어야 함
#   2. services/<svc>/.app-config.yml 에 database: { name: ... } 또는 { ref: ... } 선언 후 push

on:
  workflow_dispatch:
    inputs:
      service-name:
        description: "모노레포 서비스 이름 (services/<name>). .app-config.yml.database 가 선언된 서비스"
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
          set -euo pipefail
          CONFIG_PATH="services/${SERVICE}/.app-config.yml"
          if [ ! -f "$CONFIG_PATH" ]; then
            echo "::error::${CONFIG_PATH} not found"
            exit 1
          fi
          {
            echo "config<<__EOF__"
            cat "$CONFIG_PATH"
            echo "__EOF__"
          } >> "$GITHUB_OUTPUT"

  add-db:
    needs: read-config
    if: github.repository != 'ukkiee-dev/app-starter'
    uses: ukkiee-dev/homelab/.github/workflows/_add-database.yml@main
    with:
      app-name:     ${{ github.event.repository.name }}
      service-name: ${{ inputs.service-name }}
      config-yaml:  ${{ needs.read-config.outputs.config }}
    secrets:
      APP_ID:               ${{ secrets.HOMELAB_APP_ID }}
      APP_PRIVATE_KEY:      ${{ secrets.HOMELAB_APP_PRIVATE_KEY }}
      TF_ACCOUNT_ID:        ${{ secrets.TF_ACCOUNT_ID }}
      R2_ACCESS_KEY_ID:     ${{ secrets.R2_ACCESS_KEY_ID }}
      R2_SECRET_ACCESS_KEY: ${{ secrets.R2_SECRET_ACCESS_KEY }}
      TELEGRAM_BOT_TOKEN:   ${{ secrets.TELEGRAM_BOT_TOKEN }}
      TELEGRAM_CHAT_ID:     ${{ secrets.TELEGRAM_CHAT_ID }}
```

**Step 8.3: YAML 검증**

```bash
yq eval '.' .github/workflows/add-database.yml > /dev/null && echo "✅ valid"
yq '.on.workflow_dispatch.inputs | keys' .github/workflows/add-database.yml
yq '.jobs | keys' .github/workflows/add-database.yml
```

Expected: valid, inputs=1 (service-name), jobs=2 (read-config, add-db).

**Step 8.4: Commit + PR**

```bash
git add .github/workflows/add-database.yml
git commit -m "feat: add-database.yml caller — 기존 서비스에 DB 추가

homelab _add-database.yml 호출. .app-config.yml 의 database 블록 기반 자동 생성.
create-app.yml 과 동일한 read-config job 패턴 사용."

git push -u origin feat/add-database-caller
gh pr create --base main --title "feat: add-database.yml caller 추가" --body "homelab #<PR 7 번호> 연동. 기존 서비스에 \`.app-config.yml.database\` 추가 후 dispatch."
gh pr merge --squash --delete-branch
```

---

## Task 9: 문서 갱신 (선택 — runbook 에 새 워크플로우 언급)

**목적**: cnpg-new-project.md 에 "기존 서비스에 DB 추가" 섹션 추가.

**Files:**
- Modify: `/Users/ukyi/homelab/docs/runbooks/postgresql/cnpg-new-project.md`

**Step 9.1: 시나리오 A (기존 앱에 DB 추가) 섹션 업데이트**

현재 runbook 라인 107 부근 "기존 앱에 DB 추가" 섹션에 다음 내용 반영:
- `.app-config.yml` 에 `database.name` (owner) 또는 `database.ref` (reference) 추가
- 앱 레포에서 `gh workflow run add-database.yml -f service-name=<svc>` dispatch
- 멱등성 주의사항 (재실행 안전, 하지만 name 변경은 차단)

**Step 9.2: Commit**

```bash
git checkout -b docs/add-database-runbook
# 섹션 수정
git add docs/runbooks/postgresql/cnpg-new-project.md
git commit -m "docs(runbook): add-database.yml 시나리오 추가"
git push -u origin docs/add-database-runbook
gh pr create --base main --title "docs(runbook): cnpg-new-project add-database 시나리오"
gh pr merge --squash --delete-branch
```

---

## 검증 계획

### Phase 별 수락 기준

| Task | 검증 명령 | 기대 결과 |
|------|-----------|-----------|
| 1 | `yq eval '.' _add-database.yml` | ✅ valid |
| 2 | Parse config 시뮬레이션 5 케이스 | 4 정상 rc=0, 1 에러 rc=1 |
| 3 | Validate 시뮬레이션 8 케이스 | 5 정상, 3 에러 |
| 4 | step 개수 확인 | 7 step (Generate token~reference) |
| 5 | idempotent mock (2회 실행) | common/ 1개 유지, ignoreDifferences 1개 유지 |
| 6 | 최종 step 수 | 10 step |
| 7 | PR 머지 | homelab main 에 `_add-database.yml` 반영 |
| 8 | app-starter caller 머지 | `add-database.yml` 2 input (service-name) |

### End-to-end 검증 (머지 후)

**시나리오 1 — reference 모드 (낮은 리스크)**:
1. pokopia-wiki 에 새 worker 서비스 추가 (`pnpm service:add worker --type worker`)
2. `services/worker/.app-config.yml` 에 `database: { ref: api }` 추가 후 push
3. homelab build.yml 이 image build/update-manifest 처리 (worker deployment 생성)
4. `gh workflow run add-database.yml -f service-name=worker` dispatch
5. 검증:
   - `kubectl get deploy -n pokopia-wiki worker -o jsonpath='{.spec.template.spec.containers[0].env}'` 에 PGHOST 등 5개
   - Pod 재시작 후 Running
   - 실제 DB 쿼리 가능

**시나리오 2 — owner 모드 (테스트 레포)**:
1. 새 테스트 레포 생성 + create-app (DB 없이)
2. `.app-config.yml` 에 `database: { name: testdb }` 추가 + push
3. `gh workflow run add-database.yml -f service-name=api` dispatch
4. 검증:
   - `kubectl get cluster -n <app> <app>-pg` Ready
   - `kubectl get database -n <app>` applied=true
5. teardown: `gh workflow run teardown.yml -f app-name=<app>`

### 회귀 테스트

- 기존 create-app.yml 호출 정상 동작 (이 PR 은 신규 파일만 추가)
- `_sync-app-config.yml` 의 immutability guard (Phase 7) 와 충돌 없음 (guard 는 push 경로, add-database 는 dispatch 경로)

---

## Out of Scope

- **DB 제거 워크플로우** (`_remove-database.yml`): `.app-config.yml` 에서 database 블록 삭제 시 common/ 제거 + env 제거. 별도 설계 필요 (teardown 서비스 모드와 유사).
- **DB 이름 변경 자동 마이그레이션**: pg_dump → restore 자동화. Runbook 수준 (이미 문서화).
- **`.app-config.yml.database.role` 필드**: 기본값 = service-name. 필요 시 별도 확장.

---

## 성공 기준

- [ ] homelab PR 머지 + `_add-database.yml` main 반영
- [ ] app-starter PR 머지 + `add-database.yml` main 반영
- [ ] Parse config / Validate / owner post-processing 모든 시뮬레이션 통과
- [ ] end-to-end: reference 시나리오 성공 (pokopia-wiki worker 에 DB env 주입)
- [ ] 재실행 시 `::notice::이미 구성 완료` + git diff 비어있음 (idempotent)
- [ ] `database.name` 변경 시도 시 `::error::` + 마이그레이션 가이드
