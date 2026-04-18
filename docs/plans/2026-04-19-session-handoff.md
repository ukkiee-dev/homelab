# 2026-04-19 세션 인수인계 — 모노레포 지원 + app-starter publish + pokopia-wiki 리팩토링

| 항목 | 값 |
|---|---|
| **세션 목적** | 홈랩 배포 파이프라인에 모노레포 개념 도입, 재사용 가능한 앱 시작 템플릿 구축, pokopia-wiki 구조 정리 |
| **완료 일자** | 2026-04-19 |
| **영향 레포** | `ukkiee-dev/homelab`, `ukkiee-dev/app-starter`(신규), `ukkiee-dev/pokopia-wiki`(로컬만) |

---

## 1. 완료된 작업

### 1.1 homelab — 모노레포 + F안 규약 + DX 개선

| Commit | 내용 |
|---|---|
| `163d334` | **setup-app · teardown · _update-image · _sync-app-config 에 `service-name` input 추가** — flat / monorepo 분기. 3-way teardown(flat/service/project). apps.json 키 `<app>-<service>` 규약. tunnel 다중 hostname · GHCR 다중 패키지 처리. |
| `c5bca4d` | **`build-and-push` composite action 신설** — F안 규약 강제 (services/`<service>`/Dockerfile, 이미지 `<app>-<service>`). 앱 레포 build.yml 의 matrix caller에서 호출. |
| `eae7b1a` | **README 대폭 갱신** — 모노레포 · composite action · 3-way teardown · 앱 유형 2가지 설명 |
| `34ff9ce` | **.gitignore 에 `.claude/scheduled_tasks.lock` 추가** — Claude Code 런타임 파일 제외 |

### 1.2 app-starter — 새 레포 publish

- **URL**: https://github.com/ukkiee-dev/app-starter
- **Template 등록**: ✓ (`gh repo edit --template`)
- **첫 commit**: `502f5d0 chore: 초기 scaffold`

핵심 구성:
- pnpm workspace 모노레포 — `services/*` (자립형 tsconfig)
- 서비스 타입 3종: `web`(hono) / `static`(react+Caddy) / `worker`
- Generator 스크립트:
  - `pnpm run setup` — placeholder 치환
  - `pnpm service:add` — 대화형(@clack/prompts) UI · 화살표 선택 · type×framework 레이어
  - `pnpm test:gen`, `pnpm test:sandbox` — 템플릿 자체 테스트
- Node 24 native TypeScript 실행 (tsx 불필요 — macOS Unix socket 경로 제한 회피)
- CI `build.yml`: 동적 `discover` job이 `services/*/Dockerfile` 스캔 matrix 생성. `if: github.repository != 'ukkiee-dev/app-starter'` 가드로 template 자체 CI skip.
- SPA env: Vite 빌드 타임 인라인 (`import.meta.env.VITE_*`) + Dockerfile `ARG/ENV` 로 build-args 주입

### 1.3 pokopia-wiki — 디렉토리 리팩토링 (로컬 branch)

- Branch: `feat/restructure-services-dir` (⚠️ push 보류 중 — 사용자 의지)
- Commit: `3543bc4 refactor: 모노레포 디렉토리 재구성 — packages/* → services/* + shared/`
- 주요 변경: `packages/{api,scraper}` → `services/{api,scraper}`, `packages/shared` → `shared/`. pnpm-workspace, Dockerfile, Prisma generator output, `.claude/agents`·`.claude/skills` 경로 하드코딩 일괄 수정 (97 파일). `_workspace/audit/*`·`_workspace/phase-*/*`·`docs/plans/2026-04-18-*.md` 는 과거 스냅샷이라 보존.

---

## 2. 남은 작업

우선순위 · 의존성 순으로.

### P1. pokopia-wiki 리팩토링 branch push + PR 병합

**상태**: 로컬 `feat/restructure-services-dir` commit 준비 완료. Remote 미설정.

**액션**:
```bash
cd /Users/ukyi/workspace/pokopia-wiki

# 1) remote 레포 확인/생성
gh repo view ukkiee-dev/pokopia-wiki 2>&1 || \
  gh repo create ukkiee-dev/pokopia-wiki --private --source=. --push

# 이미 있으면
git remote add origin git@github.com:ukkiee-dev/pokopia-wiki.git
git push -u origin main
git push -u origin feat/restructure-services-dir

# 2) PR 생성 & 병합
gh pr create --base main --head feat/restructure-services-dir \
  --title "refactor: 모노레포 디렉토리 재구성 — packages/* → services/*"
```

**검증** (병합 후):
- main 의 pnpm install · type-check · test 통과 확인
- 기존 CI 워크플로우 (ci.yml) 가 새 경로에서 정상 동작

---

### P2. pokopia-wiki → homelab 첫 프로비저닝 (api 서비스)

**전제**: P1 완료.

**액션**:
```bash
# homelab 에 pokopia-wiki 프로젝트 shell + api 서비스 생성
gh workflow run _create-app.yml --repo ukkiee-dev/homelab \
  -f app-name=pokopia-wiki \
  -f app-type=web \
  -f service-name=api \
  -f subdomain=wiki
```

**자동 생성되는 것**:
- `apps.json` 에 `pokopia-wiki-api` 엔트리
- Cloudflare DNS `wiki.ukkiee.dev` + Tunnel ingress
- `manifests/apps/pokopia-wiki/common/` (NP, pull secret) + `services/api/` (Deployment, Service, IngressRoute)
- ArgoCD `Application` : `pokopia-wiki`

**검증**:
- ArgoCD 에서 `pokopia-wiki` Application Healthy 도달
- 첫 이미지 빌드: pokopia-wiki 레포 main push → `ghcr.io/ukkiee-dev/pokopia-wiki-api:<sha>` push → homelab 매니페스트 auto update → Pod 실제 기동

---

### P3. pokopia-wiki scraper 서비스 추가

**전제**: P2 완료. pokopia-wiki 레포에 `services/scraper/Dockerfile` 작성 필요.

```bash
# Dockerfile 준비 후 (build.yml matrix 자동 감지)
gh workflow run _create-app.yml --repo ukkiee-dev/homelab \
  -f app-name=pokopia-wiki \
  -f app-type=worker \
  -f service-name=scraper
  # subdomain 비움 → worker 매니페스트(Deployment만)
```

---

### P4. DB 프로비저닝 — 3-role SealedSecret + PreSync Job

**전제**: P2 이후, pokopia-wiki api 가 PostgreSQL 연결 필요해지면.

**설계 합의 (이전 세션)**:
- 3-role 분리: `<db>_migrate` (OWNER · DDL) / `<db>_api` (DML) / `<db>_worker` (DML)
- `db-provision-job.yaml` — PreSync hook · idempotent `CREATE ROLE / CREATE DATABASE / GRANT / DEFAULT PRIVILEGES`
- `scripts/seal-db-secret.sh` — role별 SealedSecret 생성
- 선행 요건: **homelab 에 `SEALED_SECRETS_CERT` GHA secret 등록**
  ```bash
  kubectl --context orbstack -n kube-system get secret \
    -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
    -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d > /tmp/ss-cert.pem
  gh secret set SEALED_SECRETS_CERT --repo ukkiee-dev/homelab < /tmp/ss-cert.pem
  rm /tmp/ss-cert.pem
  ```

**구현 대상 (homelab)**:
- `.github/actions/setup-app/action.yml` 에 `with-db` input + provision Job · SealedSecret · migrate Job 템플릿 추가
- `_create-app.yml` · `_teardown.yml` 에 DB 분기
- Phase II 리팩토링 pokopia-wiki 에 `services/api/src/db/` (Prisma client) 와 initContainer(`prisma migrate deploy`) 연결

---

### P5. composite action `build-args` input 확장 (SPA 배포 시)

**전제**: homelab 에 `static/react` 서비스가 배포될 때.

**파일**: `.github/actions/build-and-push/action.yml`

**변경 (3줄)**:
```yaml
inputs:
  # ... 기존 ...
  build-args:
    description: "docker build --build-arg 리스트 (멀티라인 KEY=VALUE)"
    required: false
    default: ""

runs:
  using: composite
  steps:
    # ... 기존 ...
    - uses: docker/build-push-action@v6
      with:
        # ... 기존 ...
        build-args: ${{ inputs.build-args }}    # ← 추가
```

→ 앱 레포 build.yml 에서 `VITE_API_URL` 같은 값을 secrets 에서 주입 가능.

---

### P6. 운영 · 모니터링 보완 (선택)

- ArgoCD Application 별 Telegram 알림 룰
- PostgreSQL 백업 CronJob (이미 존재, 주기적 검증만)
- `template-static` · `template-web` 레거시 template 레포 삭제 여부 결정 (있다면)

---

## 3. 결정 사항 요약

세션 중 확정된 원칙·결정.

| 주제 | 결정 |
|---|---|
| **서비스 디렉토리 구조** | `services/<service>/` 강제. 모노레포 F안. Dockerfile 경로 `services/<service>/Dockerfile` 고정. |
| **이미지 이름** | `ghcr.io/ukkiee-dev/<app>-<service>:<tag>` (모노레포) · `ghcr.io/ukkiee-dev/<app>:<tag>` (flat) |
| **port 통일** | 모든 HTTP 서비스 port 3000 (Caddyfile · Hono · K8s Service · IngressRoute) |
| **type 3종** | `web`(Node HTTP) · `static`(SPA) · `worker`(백그라운드). `subdomain` 유무로 매니페스트 구조 자동 분기 가능하지만 현재는 type input 유지. |
| **framework 레이어** | `templates/<type>/<framework>/`. 현재 web=hono, static=react, worker는 framework 없음. 옵션 1개면 자동 선택. |
| **SPA env** | Vite 빌드 타임 인라인 (`import.meta.env.VITE_*`). 런타임 주입 방식(`window.__ENV__`) 제거 — 홈랩 단일 환경이라 이미지 재빌드 감수. Dockerfile `ARG/ENV` 로 build-args 주입. |
| **.app-config.yml** | `health` 필드만 유지. icon/description 은 homelab `update-app-config.yml` dispatch 로 관리 (SoT 분리). |
| **Node 런타임** | 24+. app-starter 의 `.ts` 스크립트는 tsx 없이 `node --disable-warning=ExperimentalWarning` 직접 실행. |
| **pokopia-wiki Phase II** | packages/ → services/ + shared/ 전환. 과거 스냅샷(`_workspace/audit`, `_workspace/phase-*`) 은 보존. |

---

## 4. 참고 링크

- **homelab**: https://github.com/ukkiee-dev/homelab
  - `.github/actions/build-and-push/` — F안 강제 composite
  - `.github/actions/setup-app/` — 앱 스캐폴딩
  - `.github/workflows/_create-app.yml` · `_update-image.yml` · `_sync-app-config.yml` · `_teardown.yml`
- **app-starter** (template): https://github.com/ukkiee-dev/app-starter
- **pokopia-wiki**: 로컬 `/Users/ukyi/workspace/pokopia-wiki` (remote 미설정)

---

## 5. 다음 세션 시작 시 체크리스트

1. `git log --oneline -5` 로 homelab main 최신 상태 확인 (`34ff9ce` 이후 변경 있나)
2. `gh repo view ukkiee-dev/app-starter --json isTemplate` 로 template flag 유지 확인
3. pokopia-wiki 로컬 branch 상태 (`git -C /Users/ukyi/workspace/pokopia-wiki log --oneline -3`)
4. P1~P5 중 어디부터 시작할지 결정
