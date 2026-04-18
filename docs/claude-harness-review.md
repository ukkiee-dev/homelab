# Claude Harness Review — 홈랩 하네스 감사 보고서

**작성일**: 2026-04-18
**감사 대상**: `/Users/ukyi/homelab/.claude/` (프로젝트 하네스)
**참조**: `/Users/ukyi/.claude/` (글로벌 사용자 하네스)
**리뷰어**: Claude (하네스 자체 감사)

---

## Executive Summary

홈랩 하네스는 **11개 오케스트레이터 + 38개 에이전트 + 21개 스킬 + 1개 훅**으로 구성된 체계적인 자동화 체계다. 도메인 분리와 역할 매핑은 **Production-grade** 수준이나, 파일명 일관성·글로벌 스킬과의 중복·훅 오버헤드가 운영 비용을 높이고 있어 개선 여지가 크다.

**종합 건강도**: `AT_IMPROVEMENT`
- ✅ 아키텍처: 도메인 분리 우수
- ⚠️ 일관성: 파일명·frontmatter 필드 편차
- ❌ 유지성: 글로벌과 중복된 스킬 9개 (100% 동일)

**핵심 액션**:
1. 소문자 `skill.md` 6개 → `SKILL.md`로 통일 (Linux CI 파손 방지)
2. 글로벌과 동일한 스킬 9개 프로젝트에서 제거 (유지 부담 절반)
3. `skill-forced-eval-hook.sh` 조건부 활성화 또는 제거 (토큰 절감)

---

## 1. 하네스 인벤토리

### 1.1. 파일 수준 통계

| 구성 요소 | 개수 | 위치 |
|---------|------|------|
| 에이전트 | 38 | `.claude/agents/*.md` |
| 스킬 (오케스트레이터) | 11 | `.claude/skills/*/SKILL.md` |
| 스킬 (참조/knowledge) | 5 | `cluster-diagnose`, `k8s-*`, `cloudflare`, `orbstack-*` |
| 스킬 (글로벌 복제) | 5 | `brainstorming`, `humanizer`, `using-superpowers`, `writing-plans`, `finishing-a-development-branch` |
| 훅 | 1 | `UserPromptSubmit` / `skill-forced-eval-hook.sh` |
| Settings | 1 | `.claude/settings.json` |

### 1.2. 커버리지 매트릭스 (오케스트레이터 ↔ 에이전트)

| 도메인 | 오케스트레이터 스킬 | 담당 에이전트 수 | 에이전트 |
|--------|------------------|--------------|---------|
| 홈랩 운영/진단 | `homelab-ops` | 3 | manifest-engineer, cluster-ops, infra-reviewer |
| 앱 라이프사이클 | `app-lifecycle` | 4 | app-architect, provisioning-engineer, verification-agent, decommission-manager |
| 코드 리뷰 | `code-review` | 4 | arch/security/perf/style-reviewer |
| 웹/학술 리서치 | `deep-research` | 3 | web-researcher, academic-researcher, community-researcher |
| 인프라 보안 감사 | `infra-security-audit` | 4 | network/secret/container/access-auditor |
| 모니터링 | `monitoring-ops` | 4 | dashboard-designer, alert-engineer, query-optimizer, observability-reviewer |
| 리소스 최적화 | `resource-optimizer` | 3 | resource-analyst, sizing-engineer, scheduling-strategist |
| DR/백업 | `dr-verification` | 3 | backup-verifier, dr-simulator, data-protection-reviewer |
| GHA CI/CD | `gha-cicd` | 4 | workflow-builder, pipeline-reviewer, workflow-tester, pipeline-debugger |
| Terraform IaC | `terraform-iac` | 3 | iac-engineer, drift-detector, state-manager |
| 운영 문서화 | `runbook-gen` | 3 | code-analyst, runbook-writer, arch-diagrammer |
| **합계** | **11** | **38** | (전원 할당, 고아 에이전트 0개) |

**관찰**: 에이전트 38개가 정확히 오케스트레이터별 합계와 일치. 미할당된(고아) 에이전트가 없으며, 여러 오케스트레이터에서 공유되는 에이전트도 없다 — 매우 깔끔한 1:N 매핑.

---

## 2. 강점 (What Works Well)

### 2.1. 도메인 분리의 선명도
- 11개 오케스트레이터가 각기 배타적 도메인을 커버한다. 새 앱 배포(`app-lifecycle`)와 기존 앱 수정(`homelab-ops`)의 경계를 description에서 명시적으로 선언한다.
- `app-lifecycle/skill.md`에는 "단순 매니페스트 수정이나 트러블슈팅에는 트리거하지 않는다 — 그런 요청은 homelab-ops가 처리한다" 같은 **능동적 경계 선언**이 포함되어 있다.

### 2.2. 일관된 실행 패턴
모든 오케스트레이터가 다음 표준 골격을 따른다:
```
실행 모드 → 에이전트 풀 → 워크플로우(Phase별) → 데이터 흐름 → 에러 핸들링 → 테스트 시나리오
```
- `model: "opus"` 강제 (품질 우선)
- `_workspace/` 디렉토리로 중간 산출물 보존 (감사 추적)
- 재시도 1회 후 부분 결과 허용 (실패 관용성)

### 2.3. 도메인 지식의 계층화
- `homelab-ops/references/project-conventions.md`에 GitOps·ArgoCD selfHeal·Traefik·Tunnel 등 프로젝트 특유 컨벤션을 집중
- 각 오케스트레이터가 에이전트 프롬프트에 이 파일 경로를 주입하여 **일관된 컨벤션 적용**
- 플랫 `manifests/apps/<app>/` 구조, 라벨 4종, 보안 컨텍스트 기준 등이 단일 소스에서 관리됨

### 2.4. 교차 관심사 식별 메커니즘
- `code-review`: 4개 리뷰어 결과를 중복 제거 + 교차 관심사 식별 (예: "아키텍처 결함 → 보안 취약점 → 심각도 상향")
- `infra-security-audit`: 팀 모드(TeamCreate)로 감사자 간 실시간 교차 검증 (예: `network → container`, `secret → access`) → 공격 체인 탐지

### 2.5. 트리거 description 품질
- 대부분 **구체적 키워드 + 비트리거 조건**을 함께 기술
  - 양호: `resource-optimizer`는 'OOM', 'Pending', 'QoS' 등 구체 키워드 나열 + "단순 매니페스트 생성에는 트리거하지 않는다"
  - 양호: `infra-security-audit`는 "코드 보안 리뷰에는 트리거하지 않는다 — security-reviewer 담당" 명시

### 2.6. 실행 모드의 의도적 다양성
| 오케스트레이터 | 실행 모드 | 선택 이유 |
|--------------|---------|---------|
| `code-review`, `deep-research`, `monitoring-ops` | Fan-out/Fan-in 서브에이전트 | 독립 병렬 + 중앙 통합 |
| `dr-verification`, `runbook-gen`, `terraform-iac` | 순차 파이프라인 서브에이전트 | 단계 간 데이터 의존 |
| `resource-optimizer` | 전문가 풀 (상황별 선택) | 토큰 절약 |
| `infra-security-audit` | **에이전트 팀 (TeamCreate)** | 실시간 교차 검증 필요 |
| `homelab-ops`, `app-lifecycle`, `gha-cicd` | 상황별 라우팅 | 요청 유형이 다양 |

---

## 3. 문제점 (Issues)

### 🔴 Critical

#### C1. SKILL.md 파일명 대소문자 불일치
공식 `plugin-structure` 가이드는 auto-discovery의 대상으로 **대문자 `SKILL.md`**만 인식한다. 현재 프로젝트에는 두 스타일이 혼재한다.

| 스타일 | 개수 | 스킬 |
|--------|------|------|
| `SKILL.md` (공식) | 15 | brainstorming, cloudflare, cluster-diagnose, code-review, deep-research, dr-verification, finishing-a-development-branch, homelab-ops, humanizer, k8s-manifest-generator, k8s-security-policies, monitoring-ops, orbstack-best-practices, using-superpowers, writing-plans |
| `skill.md` (비공식) | 6 | **app-lifecycle, gha-cicd, infra-security-audit, resource-optimizer, runbook-gen, terraform-iac** |

**위험 시나리오**:
- macOS APFS는 기본 대소문자 무감(case-insensitive)이므로 현재 로컬에서는 동작
- 그러나 **Linux 파일시스템(CI/CD, 도커 이미지, 리포지토리 배포)**은 대소문자 감지. `skill.md`를 가진 6개 오케스트레이터가 Claude Code auto-discovery에서 누락
- 또한 Git이 대소문자 구분 이름 변경을 인식하지 못해 충돌 가능

**수정**:
```bash
git mv .claude/skills/app-lifecycle/skill.md .claude/skills/app-lifecycle/SKILL.md
# 6개 파일 모두 동일 패턴
```

#### C2. 글로벌 스킬 복제 (100% 동일 9개)

프로젝트 `.claude/skills/`에 글로벌 `~/.claude/skills/`와 **완전히 동일한 스킬 9개**가 존재한다. `diff -q`로 전수 확인한 결과 어느 파일도 차이가 없다.

| 스킬 | 프로젝트 | 글로벌 | diff 결과 |
|------|---------|-------|-----------|
| brainstorming | ✓ | ✓ | identical |
| cloudflare | ✓ | ✓ | identical |
| finishing-a-development-branch | ✓ | ✓ | identical |
| humanizer | ✓ | ✓ | identical |
| k8s-manifest-generator | ✓ | ✓ | identical |
| k8s-security-policies | ✓ | ✓ | identical |
| orbstack-best-practices | ✓ | ✓ | identical |
| using-superpowers | ✓ | ✓ | identical |
| writing-plans | ✓ | ✓ | identical |

**영향**:
- 글로벌 스킬이 업데이트될 때마다 프로젝트 복사본은 stale → 버그/드리프트 유발
- 유지보수 포인트가 2배 (저장소마다 동일 수정)
- 리포지토리 크기·git 히스토리 오염

**수정**:
```bash
# 중복 9개 디렉토리 제거 (글로벌이 자동 로드)
rm -rf .claude/skills/{brainstorming,cloudflare,finishing-a-development-branch,humanizer,k8s-manifest-generator,k8s-security-policies,orbstack-best-practices,using-superpowers,writing-plans}
```
혹은 프로젝트 특화가 필요하다면 **README나 frontmatter에 override 사유를 명시**하고 유지.

---

### 🟡 Warning

#### W1. 에이전트 color 필드 누락 (35/38)

공식 agent-development 가이드는 `color`를 required 필드로 명시한다. 현재 존재하는 것은 3개뿐이다.

| 상태 | 개수 |
|------|------|
| `color` 있음 | 3 (backup-verifier, data-protection-reviewer, dr-simulator) |
| `color` 없음 | 35 |

**영향**: Claude Code UI에서 에이전트 구분이 약화. 기본 색상으로 동작하지만, 여러 에이전트가 병렬 실행될 때(예: `code-review`의 4개 리뷰어) 시각적 트래킹이 어려움.

**제안 색상 체계**:
| 역할군 | color | 해당 에이전트 |
|--------|-------|-------------|
| Reviewer (품질 평가) | `blue` | arch-reviewer, style-reviewer, perf-reviewer, infra-reviewer, pipeline-reviewer, observability-reviewer, data-protection-reviewer |
| Auditor (위험 식별) | `yellow` | network-auditor, secret-auditor, container-auditor, access-auditor, backup-verifier |
| Engineer (생성·변경) | `green` | manifest-engineer, sizing-engineer, alert-engineer, iac-engineer, workflow-builder, provisioning-engineer |
| Researcher/Analyst | `cyan` | web/academic/community-researcher, code-analyst, resource-analyst |
| Security-critical | `red` | security-reviewer, dr-simulator |
| Generator/Designer | `magenta` | arch-diagrammer, dashboard-designer, runbook-writer, query-optimizer |
| Operational | `blue` | cluster-ops, state-manager, drift-detector, scheduling-strategist, pipeline-debugger, decommission-manager, verification-agent, workflow-tester, app-architect |

#### W2. 에이전트 description에 `<example>` 블록 부재 (38/38)

공식 가이드는 2~4개 `<example>` 블록으로 triggering 조건을 문서화하도록 권장한다. 현재는 키워드 나열만 존재.

**현재 형태**:
```yaml
description: "K8s 매니페스트 생성/수정/검증 전문 에이전트. 'manifest', '배포', ..."
```

**권장 형태**:
```yaml
description: |
  K8s 매니페스트 생성/수정/검증 전문 에이전트. ...
  
  <example>
  Context: 사용자가 새 앱 배포를 요청
  user: "Next.js 앱 배포해줘"
  assistant: "manifest-engineer를 호출하여 매니페스트 5종을 생성하겠습니다."
  <commentary>
  새 앱 배포는 manifest-engineer의 핵심 역할이며, 프로젝트 컨벤션 적용이 필요하다.
  </commentary>
  </example>
```

**영향**: 자동 에이전트 선택 정확도 저하. 맥락 기반 호출 판단이 약화.

**우선 대상**: 상위 10개 에이전트(manifest-engineer, cluster-ops, infra-reviewer, 4개 리뷰어, 3개 researcher)부터 시작.

#### W3. 훅의 토큰 오버헤드 (모든 프롬프트에 영향)

`.claude/hooks/skill-forced-eval-hook.sh`는 **모든 사용자 프롬프트**에 MANDATORY SKILL ACTIVATION SEQUENCE(약 30줄)를 주입한다.

**주입 결과** (매 요청):
```
INSTRUCTION: MANDATORY SKILL ACTIVATION SEQUENCE
Step 1 - EVALUATE ...
Step 2 - ACTIVATE ...
Step 3 - IMPLEMENT ...
```

**중복 문제**:
- `using-superpowers` 스킬(글로벌·프로젝트 양쪽에 존재)이 동일한 기능 수행
- 즉 이 훅이 없어도 `using-superpowers`가 스킬 활성화 규칙 적용

**영향**:
- 단순 질문("날짜 확인")에도 Step 1~3 의식을 요구 → 컨텍스트 낭비
- 상주 주입이라 **프롬프트 캐시 효율 저하**
- 훅과 스킬이 중첩되어 응답 장황해짐

**수정 옵션**:
| 옵션 | 방법 | 권장도 |
|------|------|-------|
| A. 훅 제거 | `settings.json`에서 훅 블록 삭제 | ⭐⭐⭐ (`using-superpowers`로 충분) |
| B. 조건부 활성화 | 특정 키워드/디렉토리에서만 | ⭐⭐ |
| C. 경량화 | 30줄 → 3줄로 축약 | ⭐ |

#### W4. 오케스트레이터 라우팅 경계 모호

사용자가 **"보안 점검해줘"** 또는 **"클러스터 보안 검토"**라 요청하면 두 스킬이 동시에 매칭될 수 있다:
- `homelab-ops` description: "'감사해줘', '보안 확인'" 포함
- `infra-security-audit` description: "'보안 감사', '보안 스캔'" 포함

**차이**:
- `homelab-ops` + `infra-reviewer`: 단일 에이전트의 종합 리뷰 (5~10분)
- `infra-security-audit` + 4명 팀: 4개 차원 깊이 감사 (15~30분)

**권장**: `homelab-ops` description 말미에 "**심층 보안 감사(Critical/High/Medium/Low 매트릭스 요청)는 infra-security-audit 사용**" 명시. 반대로 `infra-security-audit`에는 "빠른 일반 리뷰는 homelab-ops 사용" 명시.

#### W5. 네이밍 컨벤션 일관성

reviewer / auditor / analyst / verifier 구분 기준이 명확하지 않다.

| 에이전트 | 실제 역할 | 네이밍 적정성 |
|---------|---------|--------------|
| data-protection-**reviewer** | 취약점·사각지대 식별 | auditor가 더 적합 |
| observability-**reviewer** | 모니터링 완성도 검증 | reviewer OK |
| backup-**verifier** | 백업 상태 확인 | verifier OK |
| secret-**auditor** | 보안 위험 식별 | auditor OK |
| resource-**analyst** | 메트릭 분석 | analyst OK |

**제안 기준**:
- **auditor**: 보안·규정 위반 식별 (위험 기반)
- **reviewer**: 품질·설계 평가 (기준 기반)
- **analyst**: 데이터 분석·패턴 식별 (데이터 기반)
- **verifier**: 상태·결과 확인 (체크리스트 기반)
- **engineer**: 생성·변경 (산출물 기반)

**실행 비용**: 이름 변경은 의존성 리팩토링 필요(오케스트레이터의 `subagent_type` 참조 전수 수정). 신규 에이전트부터 기준 적용 권장.

---

### 🔵 Info

#### I1. 스킬 frontmatter에 `version` 필드 없음
- 공식 권장: `version`, `author`, `homepage` 선택 필드
- 현재는 `name`, `description`만 존재
- 변경 이력 추적·하위호환성 관리 부재
- **우선순위 낮음**: 내부 사용이므로 당장 필요는 없음

#### I2. 데이터 흐름 다이어그램이 ASCII art
- `resource-optimizer`, `dr-verification` 등이 ASCII로 흐름 표현
- Mermaid flowchart로 전환 시 가독성·유지성 개선
- `runbook-gen/arch-diagrammer` 에이전트를 스스로 활용하여 자동 생성 가능

#### I3. `.claude-plugin/plugin.json` 부재
- 이 하네스는 **플러그인 배포 구조**가 아닌 **프로젝트 로컬 override** 형태
- 향후 마켓플레이스나 외부 공유 시 plugin.json이 필요
- 현재 상태는 의도적이라면 OK

#### I4. `settings.json` 최소화
- 현재 `hooks` 블록만 존재, `permissions`·`env` 없음
- 프로젝트 특유의 허용 명령어(예: `kubectl`, `terraform`)를 `permissions.allow`에 등록하면 권한 프롬프트 빈도 감소
- `fewer-permission-prompts` 스킬로 자동 감사 가능

#### I5. 에이전트 협업 섹션의 비형식성
- 대부분 에이전트 `## 협업` 섹션에 자연어로 "X가 Y 시 도움을 준다"고 기술
- 이는 정보성이지 팀 통신 프로토콜이 아님
- 에이전트 팀 모드(`infra-security-audit`)에서는 SendMessage 경로가 명시되었으나, 서브에이전트 모드에서는 암묵적
- **개선 여지**: 협업 경로를 구조화된 표로 (`발신 → 수신 → 상황 → 전달 데이터`)

---

## 4. 중복·경계 심층 분석

### 4.1. 스킬 레벨 중복

| 중복 유형 | 개수 | 심각도 | 대응 |
|---------|------|-------|------|
| 프로젝트 ↔ 글로벌 100% 동일 | 9 | Critical | 프로젝트 복사본 제거 |
| 프로젝트 `skill.md` ↔ `SKILL.md` 혼재 | 6 | Critical | 대문자 통일 |
| 파일명 대소문자로 인한 잠재 중복 | 0 | - | OK |

### 4.2. 기능 영역 경계

| 경계 대상 A | 경계 대상 B | 중첩 가능성 | 구분 기준 |
|-------------|-------------|------------|---------|
| `homelab-ops` (infra-reviewer) | `infra-security-audit` (4 auditors) | 중 | 깊이 (얕은 리뷰 vs 깊이 감사) |
| `cluster-diagnose` 스킬 | `cluster-ops` 에이전트 | 낮음 (상호 보완) | 정적 체크리스트 vs 동적 진단 |
| `secret-auditor` | `data-protection-reviewer` | 낮음 | 시크릿 자체 vs 시크릿 백업 |
| `verification-agent` | `observability-reviewer` | 낮음 | 앱 배포 검증 vs 모니터링 설정 검증 |
| `infra-reviewer` 단독 | `code-review` 오케스트레이터 | 낮음 | 인프라 매니페스트 vs 앱 코드 |
| `provisioning-engineer` | `iac-engineer` | 낮음 | 앱 전체 프로비저닝 vs Terraform 코드만 |
| `app-architect` | `manifest-engineer` | 낮음 | 설계(설계도) vs 구현(YAML) |

대부분 경계 명확하나 **첫 번째 항목(homelab-ops vs infra-security-audit)은 description 보강 필요**.

### 4.3. 에이전트 간 참조 일관성

오케스트레이터들이 에이전트 프롬프트에 다음과 같은 경로를 일관되게 포함:
```
.claude/skills/homelab-ops/references/project-conventions.md     (공통 컨벤션)
.claude/skills/infra-security-audit/references/severity-criteria.md  (보안 감사)
.claude/skills/gha-cicd/references/workflow-patterns.md          (GHA)
.claude/skills/terraform-iac/references/state-management.md      (Terraform)
```

**잠재 문제**: 파일명 변경 시 모든 오케스트레이터 프롬프트를 전수 업데이트해야 함. 해결책 — **경로를 스킬 본문 상단에 상수로 선언**하고 프롬프트에서는 변수 참조.

---

## 5. 일관성 스코어카드

### 5.1. Frontmatter 필드 (38개 에이전트 대상)

| 필드 | 커버리지 | 평가 |
|------|---------|------|
| `name` | 38/38 (100%) | ✅ |
| `description` | 38/38 (100%) | ✅ |
| `model` | 38/38 (100%, 모두 opus) | ✅ |
| `color` | 3/38 (8%) | ❌ (W1) |
| `<example>` 블록 | 0/38 (0%) | ⚠️ (W2) |
| `tools` 제한 | 0/38 (0%) | ⚪ (의도적 — 전체 권한) |

### 5.2. 스킬 Frontmatter (21개 스킬 대상)

| 필드 | 커버리지 |
|------|---------|
| `name` | 21/21 ✅ |
| `description` | 21/21 ✅ |
| `version` | 0/21 ⚪ |

### 5.3. 오케스트레이터 구조 필수 섹션 (11개 대상)

| 섹션 | 커버리지 |
|------|---------|
| 실행 모드 선언 | 11/11 ✅ |
| 에이전트 풀/구성 테이블 | 11/11 ✅ |
| 워크플로우 (Phase별) | 11/11 ✅ |
| 에러 핸들링 표 | 11/11 ✅ |
| 테스트 시나리오 (정상 + 에러) | 11/11 ✅ |
| 데이터 흐름 다이어그램 | 8/11 (73%) — runbook-gen, resource-optimizer 등은 있음, homelab-ops 등은 없음 |
| 기존 스킬/에이전트 연동 섹션 | 8/11 (73%) |

### 5.4. 파일명 일관성

| 대상 | 일관성 |
|------|-------|
| 에이전트 `*.md` | 38/38 ✅ (소문자-하이픈) |
| 스킬 디렉토리명 | 21/21 ✅ (소문자-하이픈) |
| 스킬 본체 `SKILL.md` | 15/21 ❌ (6개가 `skill.md`) |

---

## 6. 훅 감사

### 6.1. 현재 상태

**파일**: `.claude/hooks/skill-forced-eval-hook.sh` + `settings.json`

**등록 이벤트**: `UserPromptSubmit` (모든 사용자 프롬프트)

**동작**: 각 프롬프트 앞에 30줄짜리 `MANDATORY SKILL ACTIVATION SEQUENCE` 지시를 추가

### 6.2. 문제

1. **기능 중복**: `using-superpowers` 스킬이 동일 규칙("1% 가능성이면 스킬 호출")을 전파
2. **토큰 낭비**: 모든 요청에 비용. 단순 질문에도 Step 1~3 강요
3. **캐시 저해**: 프롬프트 cache prefix가 변하지 않아도 매 요청 주입 → 프롬프트 캐시 히트율 영향

### 6.3. 권장

**옵션 A (권장)**: 훅 제거
```json
// .claude/settings.json
{
  // "hooks": {...} 블록 삭제
}
```
`using-superpowers` 스킬만으로 충분 (1% 규칙 동일 제공).

**옵션 B**: 조건부 활성화 (유지해야 한다면)
```bash
#!/bin/bash
# 특정 디렉토리·키워드에서만 활성화
FLAG_FILE="$CLAUDE_PROJECT_DIR/.enable-skill-eval"
[ -f "$FLAG_FILE" ] || exit 0
# 기존 내용
```

---

## 7. 개선 권장사항 (Top 10)

### 우선순위 1 — 즉시 (오늘)

1. **SKILL.md 통일**: 6개 파일 `skill.md` → `SKILL.md`
   ```bash
   cd .claude/skills
   for d in app-lifecycle gha-cicd infra-security-audit resource-optimizer runbook-gen terraform-iac; do
     git mv "$d/skill.md" "$d/SKILL.md"
   done
   ```

2. **중복 스킬 제거**: 글로벌과 100% 동일한 9개 디렉토리 삭제
   ```bash
   rm -rf .claude/skills/{brainstorming,cloudflare,finishing-a-development-branch,humanizer,k8s-manifest-generator,k8s-security-policies,orbstack-best-practices,using-superpowers,writing-plans}
   ```

3. **훅 재검토**: `skill-forced-eval-hook.sh` 제거 또는 조건부 활성화

### 우선순위 2 — 1주 내

4. **에이전트 color 추가**: 38개 에이전트에 역할별 color 일괄 추가 (섹션 3.1 W1의 색상 체계 적용)

5. **오케스트레이터 경계 보강**: `homelab-ops` description에 "심층 보안 감사는 infra-security-audit 사용" 명시

6. **에이전트 description `<example>` 블록 추가**: 상위 10개 에이전트부터 (manifest-engineer, cluster-ops, infra-reviewer, 4 리뷰어, 3 researcher)

### 우선순위 3 — 1개월 내

7. **네이밍 컨벤션 문서화**: auditor/reviewer/analyst/verifier 구분 기준을 `.claude/CONVENTIONS.md`에 정리

8. **데이터 흐름 Mermaid 전환**: ASCII 다이어그램을 Mermaid flowchart로 (arch-diagrammer 활용 자동화 가능)

9. **스킬 version 필드 도입**: 변경 이력 추적을 위해 `version: "1.0.0"` 추가

10. **settings.json 보강**: 프로젝트 특유 허용 명령어 등록으로 권한 프롬프트 감소 (`fewer-permission-prompts` 스킬 활용)

---

## 8. 액션 체크리스트

### 즉시 실행 가능 (오늘)
- [ ] `skill.md` → `SKILL.md` 6개 파일 rename
- [ ] 글로벌 복제 스킬 9개 디렉토리 제거
- [ ] `skill-forced-eval-hook.sh` 및 settings.json 훅 블록 정리
- [ ] 커밋 메시지: `chore: .claude 하네스 일관성 정리 (SKILL.md 통일, 중복 스킬 제거)`

### 이번 주
- [ ] 38개 에이전트 color 필드 일괄 추가 (스크립트 활용)
- [ ] `homelab-ops`, `infra-security-audit` description에 경계 문구 보강
- [ ] 상위 10개 에이전트에 `<example>` 블록 추가

### 장기
- [ ] 네이밍 컨벤션 문서 작성
- [ ] 오케스트레이터 Mermaid 전환
- [ ] 스킬 version 필드 도입
- [ ] settings.json permissions 보강
- [ ] 에이전트 협업 섹션을 구조화된 표로 전환

---

## 9. 정량적 평가

| 지표 | 점수 | 근거 |
|------|------|------|
| 도메인 분리 | 9.5/10 | 11개 오케스트레이터의 배타적 커버리지 |
| 에이전트 할당 | 10/10 | 38/38 완전 매핑, 고아 0 |
| 실행 모드 적합성 | 9/10 | 서브에이전트·팀·파이프라인 혼용 (적절) |
| Frontmatter 일관성 | 6/10 | color 3/38, example 0/38 |
| 파일명 일관성 | 5/10 | skill.md 6개 (Linux 호환성 위험) |
| 중복 관리 | 3/10 | 9개 스킬 글로벌 복제 |
| 훅 설계 | 5/10 | 기능 중복, 토큰 오버헤드 |
| 참조 지식 계층화 | 9/10 | project-conventions.md 중심 체계 우수 |
| 테스트 시나리오 | 8/10 | 11/11 오케스트레이터에 정상 + 에러 시나리오 |
| 문서화 | 7/10 | 섹션 구조 일관, 예시 풍부, 다이어그램은 ASCII 한계 |

**총점**: 71.5 / 100 (**AT_IMPROVEMENT**)

**개선 후 예상**: 10개 권장 적용 시 90+ 달성 가능.

---

## 10. 종합 결론

홈랩 하네스의 **아키텍처는 Production-grade**다. 11개 도메인을 38개 에이전트로 빈틈없이 커버하고, `homelab-ops ↔ app-lifecycle` 같이 경계가 겹치기 쉬운 오케스트레이터 간 분리도 명시적이다. `project-conventions.md`를 중심으로 한 도메인 지식 계층화도 잘 설계되었다.

그러나 **운영 성숙도**에서 3가지 구조적 부채가 관찰된다:
1. **파일명 일관성 부재**: 6개 `skill.md` → Linux CI 호환성 위험
2. **글로벌 스킬 복제**: 9개 스킬 100% 중복 → 유지 부담 2배
3. **훅 기능 중복**: `using-superpowers` 스킬과 중복되어 토큰 낭비

이 3가지는 **모두 1일 내 해소 가능한 기계적 수정**이다. 해소 시 하네스 점수는 71.5 → 90+로 급상승한다.

중장기 개선(W1~W5, I1~I5)은 선택사항이나, 특히 **에이전트 color 추가**와 **`<example>` 블록 도입**은 자동 에이전트 선택 정확도를 높이므로 빠르게 적용할 가치가 있다.

---

**다음 리뷰 권장 시기**: 위 Top 3 수정 후 1개월 (2026-05-18 경) — 개선 효과 및 장기 개선사항 진행 상황 점검

**참조 문서**:
- `.claude/skills/homelab-ops/references/project-conventions.md` — 프로젝트 컨벤션
- 공식 `plugin-structure`, `agent-development`, `skill-development` 가이드
- `harness` 메타 스킬 워크플로우
