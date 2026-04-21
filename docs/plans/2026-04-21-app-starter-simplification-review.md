# app-starter 단순화 Plan 리뷰

> 대상 문서: [`2026-04-21-app-starter-simplification.md`](./2026-04-21-app-starter-simplification.md)
> 리뷰 일자: 2026-04-21
> 리뷰 범위: plan 전체 + 실제 코드(`_create-app.yml`, `setup-app/action.yml`, `_sync-app-config.yml`) 대조

---

## 요약

plan 의 구조와 단계 분할은 탄탄하지만 **실행 시 실패하는 Critical 이슈 4건** 과 **정합성이 부족한 Medium 이슈 5건**이 있다. 특히 Phase 2 의 근본 전제(앱 레포 checkout)가 깨져 있어 해당 Phase 를 착수하기 전에 토큰 전략 재설계가 필수다.

| 심각도 | 건수 | 머지 전 해결 필요 |
|--------|------|------|
| Critical | 4 | ✅ 모두 |
| Medium | 5 | ✅ M1–M2 plan 수정 / M3–M5 문서 보강 |
| Minor | 6 | 선택 |

---

## 🔴 Critical (이대로 실행하면 실패)

### C1. GitHub App 토큰 범위가 `homelab` 에만 제한됨

**위치:** Phase 2 Step 2.1 (`actions/checkout` 으로 앱 레포의 `.app-config.yml` sparse-checkout)

**문제:**
- `_create-app.yml:112-114`, `_sync-app-config.yml:41-44`, `_teardown.yml:48`, `_update-image.yml:39`, `audit-orphans.yml:23`, `update-app-config.yml:46` 모두 GitHub App token 을 `repositories: homelab` 으로 **명시적 제한**.
- 이 토큰으로 앱 레포를 fetch 하면 `403 Forbidden` 으로 실패.
- plan 은 "기존 `app-token` 재사용 가능, 앱 레포 permissions 확장" 이라고만 언급하고 구체적 방법이 없음.

**해결 옵션:**
1. `repositories: [homelab, <app-name>]` 로 동적 확장 — 단 GitHub App installation 에 해당 레포가 포함되어 있어야 함.
2. `repositories` 필드 제거 후 installation 전체 범위 토큰 발급 — 보안 범위 확장 주의.
3. **[권장]** 앱 레포 caller 가 `secrets.GITHUB_TOKEN` 으로 `.app-config.yml` 내용을 읽어 `workflow_call input` 으로 전달 (plan §3.1 재설계 필요: 입력이 2개가 아니라 `service-name`, `subdomain`, `config-yaml` 3개).

**영향:** Phase 2 의 전체 전제가 깨짐. 토큰 전략을 먼저 확정해야 plan 을 재작성 가능.

---

### C2. static 템플릿 Dockerfile `COPY ../../` 는 Docker 문법 위반

**위치:** Phase 5.1

**문제:**
```dockerfile
COPY ../../pnpm-workspace.yaml ../../package.json ../../pnpm-lock.yaml ./
```
Docker build context 는 **상위 디렉토리로 탈출 불가**. Docker daemon 이 `forbidden path outside the build context` 로 거부함.

**해결:** build context 를 레포 루트로 잡고 다음과 같이 작성:
```dockerfile
FROM node:22-alpine AS builder
WORKDIR /app
COPY pnpm-workspace.yaml package.json pnpm-lock.yaml ./
COPY services/_template-static ./services/_template-static
RUN corepack enable && pnpm install --frozen-lockfile --filter _template-static...
RUN pnpm --filter _template-static build

FROM caddy:2-alpine
COPY --from=builder /app/services/_template-static/dist /srv
COPY services/_template-static/Caddyfile /etc/caddy/Caddyfile
EXPOSE 3000
```
빌드 명령은 `docker build -f services/_template-static/Dockerfile .` (context=루트).

**사전 확인:** `app-starter/build.yml` 의 Dockerfile 감지·빌드 규약이 context=루트인지, context=서비스 디렉토리인지 먼저 확인 필요. web 템플릿과 동일한 규약을 따라야 함.

---

### C3. `_create-app.yml` 입력 축소 시 caller 호환성 파손

**위치:** Phase 3 (homelab 입력 13 → 3)

**문제:**
- GitHub Actions reusable workflow 는 **unknown input 전달 시 `startup_failure`** 로 거부.
- Phase 3 을 먼저 머지하면 test-web·pokopia-wiki·기존 앱들이 여전히 `app-type`, `database-enabled` 등을 전달 → 즉시 **모든 create-app 호출 실패**.
- plan §5 는 "30분 이내 연속 머지" 로 완화한다고 썼으나, app-starter·test-web·pokopia-wiki 는 **별도 레포**. PR 승인·mergeable·CI 대기 시간을 고려하면 30분 보장 불가. 머지 창 사이 기존 앱이 `create-app` dispatch 시 터짐.

**해결 (권장 migration path):**
1. **PR 3 은 입력 제거 대신 기존 입력을 모두 `required: false`** 로 남겨두고 silently ignore 처리 (deprecation notice 추가).
2. 모든 caller(app-starter·test-web·pokopia-wiki) 업데이트 PR 이 머지된 후 **별도 후속 PR** 로 deprecated 입력 제거.

이 방식은 plan §5 완화책보다 안전하며 호환성 갭이 0 에 가까움.

---

### C4. End-to-end 검증의 `project: apps` 기대와 실제 코드 불일치

**위치:** §6.2 Step 5

**문제:**
> - [ ] ArgoCD Application project=apps, ignoreDifferences 자동 포함

- 현재 `setup-app/action.yml:764, 817` 은 **`project: default`** 로 Application 생성.
- memory `project_cnpg_operational_notes.md` 는 `project=apps` 를 **CNPG 운영 규약**으로 명시.
- plan 은 이 불일치를 해결하는 step 을 **포함하지 않음**.

**해결:**
- PR 2 (setup-app 수정) 에 `project: apps` 로 변경하는 step 명시적 추가.
- 기존 Application 들의 project 마이그레이션 계획이 별도로 필요한지 검토 (기존 앱 영향 평가 포함).

---

## 🟡 Medium

### M1. `database` 블록 immutability 구현 누락

plan 머리말:
> 이후 `.app-config.yml` 변경 시 기존 `_sync-app-config.yml` 워크플로우가 health/icon/description 을 재반영 (database 블록은 immutable — drift 방지).

**문제:** immutability 를 **보장하는 로직이 코드·step 어디에도 기술되지 않음**.

- 현재 `_sync-app-config.yml` 은 icon/description/health 만 반영하므로 사용자가 `database.name` 을 변경해도 조용히 무시됨 → 사용자 혼란.
- Phase 7 또는 별도 Phase 에서 `_sync-app-config.yml` 에 **"database 블록 변경 감지 시 warning 또는 실패"** step 을 추가해야 함.

**권장 구현:**
- homelab 기존 매니페스트 (`manifests/apps/<app>/common/cluster.yaml`) 의 DB 설정과 `.app-config.yml` 의 `database` 블록을 비교.
- 차이 있으면 `::error::` 또는 `::warning::` 로그 + 커밋 생성 차단 또는 PR 코멘트.

---

### M2. DB reference 모드 현재 미구현 상태

**위치:** `setup-app/action.yml:851-852`
```yaml
if: inputs.database-enabled == 'true' && inputs.service-name != '' && inputs.database-mode == 'owner'
```

**문제:** **reference 모드는 현재 DB composite 호출 자체가 없음.** Phase 6 은 "reference 모드 env 주입 로직 추가" 라고 쓰였지만 실제로는 **신규 기능 구현** 수준이지 "판단 로직 추가" 가 아님.

**영향:**
- `database/action.yml` 의 reference 경로가 이미 있는지 먼저 검증 필요.
- Phase 6 추정 2시간이 과소평가. reference 경로 자체를 새로 구현해야 한다면 4+ 시간으로 재산정.

**검증 방법:**
```bash
grep -n "mode" .github/actions/setup-app/database/action.yml
```
reference 케이스 별도 step 이 있는지, env 주입이 구현되어 있는지 확인 후 범위 조정.

---

### M3. 포트 통합(D1=3000) 리스크 재검증 필요

**문제:** plan 은 "static 앱 현재 사용 사례 없음" 이라 단정했지만 **명시적 검증 근거가 plan 에 없음**.

**검증 필요:**
```bash
grep -rn "containerPort: 8080" manifests/apps/
grep -rn "app.kubernetes.io/component: static" manifests/apps/
```
- 결과 0 이면 plan 의 가정이 맞음 (신규 앱만 영향).
- 0 이 아니면 rolling migration 필요.

**plan 보강:** §3 또는 §5 에 "현재 `type: static` 앱 0개 (검증 완료: `<date>`)" 명시.

---

### M4. yq 설치 타이밍 누락

**문제:**
- 현재 `setup-app/action.yml:137` 의 `Install yq` step 은 **"Add tunnel ingress" 뒤**에 위치.
- plan Step 2.1 (앱 레포 checkout) 과 Step 2.2 (yq 파싱) 은 apps.json/terraform 단계 **전**에 실행되어야 type·description 을 manifests 생성에 사용 가능.
- yq 설치 위치를 **앱 레포 checkout 직후, apps.json 수정 전**으로 앞당겨야 함.

**plan 보강:** Phase 2 에 명시적 step 순서 도표 또는 diff 추가.

---

### M5. Phase 2 PR 과 caller 상태의 병존 기간

**문제:**
- Phase 2 (setup-app 이 `.app-config.yml` 읽기 시작) 머지 후 Phase 4/5 (caller 간소화) 전까지:
  - caller 는 여전히 `app-type=web`, `default-icon=mdi-xxx` 등 전달.
  - setup-app 은 `inputs.type` 을 더 이상 쓰지 않고 `.app-config.yml` 로만 결정.
  - **테스트 앱에 `.app-config.yml` 이 없는 상태로 기존 dispatch 하면 기본값 `web` 이 강제 적용 → caller 가 보낸 `app-type=worker` 가 silently 무시됨.**
- plan 이 이 갭을 §5 한 줄로만 인지.

**권장 완화:**
- Phase 2 에서 `.app-config.yml` 이 있으면 우선, 없으면 `inputs.type`/`inputs.app-health` 등 **fallback** 로직을 **한 PR 안에 hybrid** 로 구현.
- caller 업데이트 PR 들이 여유롭게 머지된 후, 별도 cleanup PR 에서 input fallback 제거.
- 이 hybrid 방식이 C3 해결책과 자연스럽게 결합됨.

---

## 🟢 Minor

### m1. 입력 개수 표기 혼동
- §3.2 제목 "12개 → 2개" 는 app-starter caller 기준.
- §3.3 "13개 → 3개" 는 reusable `_create-app.yml` 기준.
- 머리말의 "12개 → 2개" 와 §4.3 이 서로 다른 층위를 지칭 → 독자 혼동.
- **권장:** 두 층위를 명확히 구분한 표 추가.

### m2. §6.1 Phase 3 검증 명령 렌더링
- `yq '.on.workflow_call.inputs | keys' _create-app.yml` 의 pipe(`|`) 가 마크다운 테이블에서 이스케이프 필요.
- **수정:** `` `yq '.on.workflow_call.inputs \| keys'` `` 또는 코드블록 분리.

### m3. §1 변경 대상 표에 README 누락
- §7.4 는 app-starter README 완성을 언급하지만 §1 의 변경 대상 표에는 `services/_template-*/` 와 README.md 만 있고 **§5.6 static README 섹션 업데이트**도 표에 반영되지 않음.
- **수정:** §1 표에 README 변경 범위를 Phase 1·5·7 별로 명시.

### m4. Caddyfile directive 순서
현재:
```caddyfile
:3000 {
    root * /srv
    file_server
    try_files {path} /index.html
    encode gzip

    @health path /health /healthz
    respond @health 200
    ...
}
```
**문제:** Caddy v2 는 directive 를 선언 순서가 아니라 **지정된 우선순위**로 실행하지만, 명시적 `handle` 없이 혼재 시 동작이 불명확할 수 있음. SPA fallback 이 `/health` 를 가로채지 않도록 `handle` 블록으로 분리 권장:
```caddyfile
:3000 {
    encode gzip
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        Referrer-Policy strict-origin-when-cross-origin
    }

    handle /health /healthz {
        respond 200
    }

    handle {
        root * /srv
        try_files {path} /index.html
        file_server
    }
}
```

### m5. description fallback step 위치 미명시
- §2.3 스키마 표: "repo 의 description (workflow 에서 주입)" 기본값.
- Phase 3.3 이 description fetch 를 setup-app 내부로 이동시킨다고 하나, **구체적으로 `.app-config.yml.description == ""` 일 때 GitHub API fallback 하는 step 의 위치**가 미명시.
- **보강:** Phase 2 Step 2.5 또는 새 step 으로 명시.

### m6. worker 타입 + health 지정 시 경고
- `.app-config.yml` 에 `type: worker` 와 `health: /foo` 를 함께 작성할 수 있으나 worker 는 health 무시.
- yq 파싱 단계에서 `::warning::worker 타입에서는 health 가 무시됩니다` 출력 권장 (사용자 의도 불일치 감지).

---

## 추가 관찰 (plan 외 고려사항)

### Teardown 경로 점검
- memory `project_teardown_silent_failure.md` 교훈: curl timeout(exit 28) + set -e + continue-on-error 조합이 실패를 성공으로 위장.
- `.app-config.yml` 기반 재설계 후에도 **teardown 이 같은 `.app-config.yml` 을 읽어 DB 까지 정리하는지** plan 에서 언급 필요 (Phase 7 범위).

### AppProject destinations 자동 등록
- `setup-app/action.yml:928-954` 가 이미 apps/infra AppProject destinations 자동 등록 구현 (PR #18).
- plan §6.2 Step 5 가 이 동작을 재확인만 함 → OK, 단 `project: apps` (C4) 와 destinations 등록이 **같은 step 에서 일관되게** 처리되는지 확인.

### ignoreDifferences 자동 주입
- `setup-app/action.yml:868-919` 이미 CNPG Cluster ignoreDifferences 자동 추가 (Phase 6 pokopia-wiki 교훈 반영).
- plan §6.2 Step 5 기대치와 현재 코드가 일치 → OK.

---

## 우선 액션 아이템

plan 재작성 또는 진행 전 아래 4개 결정이 필요함:

1. **[C1]** 앱 레포 토큰 확보 전략 결정
   - 옵션 선택 (repositories 확장 vs installation 전체 vs caller 측 파싱)
   - 선택에 따라 Phase 2 의 구현이 크게 달라짐.

2. **[C2]** static 템플릿 Dockerfile 의 build context 규약 확정
   - app-starter `build.yml` 의 기존 Dockerfile 빌드 context 확인.
   - 동일 규약으로 _template-static Dockerfile 작성.

3. **[C3]** Migration 전략 전환
   - "입력 제거" → "deprecated 입력 silently ignore + 후속 PR cleanup" 으로 변경.
   - Phase 3 을 두 단계로 분할 (deprecation + removal).

4. **[C4]** `project: apps` 일관화
   - PR 2 범위에 포함.
   - 기존 Application 마이그레이션 영향 평가.

이 네 가지 결정을 반영해 plan 을 revise 한 후 Phase 1 착수 권장.
