# Claude 하네스 컨벤션

`.claude/` 디렉토리의 에이전트·스킬·설정 작성 규약. 일관된 역할 분리와 자동 호출 정확도를 위한 최소 표준이다.

---

## 1. 디렉토리 구조

```
.claude/
├── CONVENTIONS.md               ← 이 문서
├── settings.json                ← 프로젝트 공유 설정 (gitignored 아님)
├── settings.local.json          ← 개인 로컬 설정 (gitignored)
├── agents/
│   └── {agent-name}.md          ← 모든 에이전트 정의
└── skills/
    └── {skill-name}/
        ├── SKILL.md             ← **반드시 대문자** (Linux 호환성)
        ├── references/          ← 조건부 로딩 참조 문서
        └── assets/              ← 출력 템플릿 (SKILL.md에 로드되지 않음)
```

**중요 규칙**
- 스킬 본체는 반드시 `SKILL.md` (대문자). `skill.md` 소문자 금지.
- 에이전트·스킬 디렉토리명은 kebab-case.
- 프로젝트 `.claude/skills/`에는 글로벌 `~/.claude/skills/`와 중복되는 스킬을 두지 않는다 — 유지 부담이 2배가 된다.

---

## 2. 에이전트 네이밍 체계

에이전트 이름 접미사는 **역할의 성격**을 반영한다. 네이밍 기준이 일관되면 오케스트레이터가 에이전트를 선택할 때 실수가 줄어든다.

| 접미사 | 역할 정의 | 작업 기준 | 대표 에이전트 |
|--------|---------|---------|-------------|
| `-auditor` | **위험 식별** — 보안·규정 위반을 식별 | 위험 기반 | network-auditor, secret-auditor, container-auditor, access-auditor |
| `-reviewer` | **품질·설계 평가** — 기준 대비 적합성 평가 | 기준 기반 | arch-reviewer, style-reviewer, perf-reviewer, infra-reviewer, pipeline-reviewer, observability-reviewer, data-protection-reviewer |
| `-analyst` | **데이터 분석** — 사용량·패턴 분석으로 숫자 생산 | 데이터 기반 | resource-analyst, code-analyst |
| `-researcher` | **외부 자료 조사** — 웹·논문·커뮤니티 수집 | 출처 기반 | web-researcher, academic-researcher, community-researcher |
| `-engineer` | **생성·변경** — 매니페스트·코드·설정을 만들거나 수정 | 산출물 기반 | manifest-engineer, sizing-engineer, alert-engineer, iac-engineer, provisioning-engineer |
| `-designer` | **설계·레이아웃** — 구조를 설계 | 설계도 기반 | dashboard-designer |
| `-builder` | **워크플로우·액션 생성** | 파이프라인 기반 | workflow-builder |
| `-verifier` | **상태·결과 확인** — 체크리스트로 PASS/FAIL 판정 | 체크리스트 기반 | backup-verifier |
| `-debugger` | **실패 분석** — 오류의 근본 원인 추적 | 증거 기반 | pipeline-debugger |
| `-tester` | **테스트 전략 설계** | 시나리오 기반 | workflow-tester |
| `-strategist` | **정책·우선순위 수립** | 트레이드오프 기반 | scheduling-strategist |
| `-simulator` | **가상 시나리오 실행** — 실제 실행 없이 결과 예측 | 모델 기반 | dr-simulator |
| `-diagrammer` | **다이어그램 생성** | 시각화 기반 | arch-diagrammer |
| `-optimizer` | **쿼리·설정 최적화** | 비용 기반 | query-optimizer |
| `-writer` | **문서·Runbook 작성** | 서식 기반 | runbook-writer |
| `-architect` | **초기 설계** — 요구사항을 설계 문서로 전환 | 요구사항 기반 | app-architect |
| `-manager` | **파괴적 작업·의존성 관리** | 안전 기반 | decommission-manager |
| `-ops` | **운영·트러블슈팅** — 실시간 클러스터 진단 | 증상 기반 | cluster-ops |
| `-agent` (단독) | **다단계 검증** — 여러 체크리스트를 합친 복합 역할 | 복합 기준 | verification-agent |

**선택 원칙**
1. **결과가 숫자/데이터**면 `-analyst`, **판정(pass/fail)**이면 `-verifier` 또는 `-reviewer`, **위험 찾기**면 `-auditor`.
2. **코드·매니페스트를 생성/수정**하면 `-engineer`, **설계 문서**만 생산하면 `-architect` 또는 `-designer`.
3. **외부 리소스를 건드리면**(삭제, 폐기) `-manager` (안전 체크 포함 의미).
4. 불확실하면 상위 표의 "작업 기준" 컬럼을 참고.

---

## 3. 에이전트 색상 (`color` 필드) 체계

색상은 UI에서 에이전트 역할군을 구분하기 위함이다. Claude Code는 6색을 지원한다: `blue`, `cyan`, `green`, `yellow`, `magenta`, `red`.

| 색상 | 역할군 | 대표 에이전트 |
|------|-------|-------------|
| `blue` | Reviewer + 운영·검증 (Operational) | arch-reviewer, style-reviewer, perf-reviewer, infra-reviewer, pipeline-reviewer, observability-reviewer, data-protection-reviewer, cluster-ops, state-manager, drift-detector, verification-agent, workflow-tester |
| `yellow` | Auditor + Debugger (주의·경고 의미) | network-auditor, secret-auditor, container-auditor, access-auditor, backup-verifier, pipeline-debugger |
| `green` | Engineer (긍정·생성 의미) | manifest-engineer, sizing-engineer, alert-engineer, iac-engineer, provisioning-engineer, workflow-builder |
| `cyan` | Researcher + Analyst (탐색·분석 의미) | web-researcher, academic-researcher, community-researcher, code-analyst, resource-analyst |
| `magenta` | Designer + Generator (창의·설계 의미) | dashboard-designer, arch-diagrammer, runbook-writer, query-optimizer, scheduling-strategist, app-architect |
| `red` | Critical·파괴적·시뮬레이션 (중대 리스크) | security-reviewer, dr-simulator, decommission-manager |

**분포 목표**: 특정 색상이 전체의 40%를 넘지 않도록 한다. 현재 38개 에이전트 기준: blue 12, yellow 6, magenta 6, green 6, cyan 5, red 3.

---

## 4. 에이전트 Frontmatter 표준

```yaml
---
name: {agent-name}                  # kebab-case, 3~50자
description: "<설명>. <예시>"        # 자동 선택을 위한 트리거 키워드 + 예시
model: opus                          # 하네스 전체 일관 — opus 강제
color: {blue|cyan|green|yellow|magenta|red}  # 위 매핑 참조
# tools: 생략 가능 — 전체 권한 기본값
---
```

### description 작성 원칙

description은 Claude가 **자동으로 이 에이전트를 선택할지** 결정하는 유일한 근거다. 트리거 오류를 줄이려면 다음을 포함한다:

1. **한 문장 역할 요약** — "K8s 매니페스트 생성/수정/검증 전문 에이전트."
2. **트리거 키워드 나열** — 'manifest', '배포', '매니페스트', 'YAML 생성' 등 실제 사용자 표현
3. **2~4개 `<example>` 블록 (권장)** — 아래 템플릿 참조
4. **비트리거 명시** (선택) — "단순 테스트 질문에는 반응하지 않는다"

### `<example>` 블록 템플릿

```markdown
<example>
Context: <사용자 상황>
user: "<사용자가 할 법한 요청>"
assistant: "<어떻게 응답하고 이 에이전트를 호출할지>"
<commentary>
<왜 이 에이전트가 적합한지 설명>
</commentary>
</example>
```

### System Prompt 필수 섹션

본문(프롬프트)은 2인칭("You are …") 또는 객관형으로 작성. 필수 섹션:

1. `## 핵심 역할` — 1~2문장 책임 요약
2. `## 프로젝트 이해` — 홈랩 컨텍스트 (GitOps, ArgoCD selfHeal, Traefik, Tunnel 등 중 관련 항목)
3. `## 작업 원칙` — 행동 가이드라인 3~5개
4. `## 입력/출력 프로토콜` — 기대 입력과 산출물 형식
5. `## 에러 핸들링` — 실패 케이스별 대응
6. `## 협업` — 어떤 다른 에이전트와 어떻게 연결되는지

---

## 5. 스킬 Frontmatter 표준

```yaml
---
name: {skill-name}
description: "<pushy description>. '트리거키워드1', '트리거키워드2', … 에 반응."
version: "1.0.0"
---
```

### description 작성 원칙

스킬 description은 오토 트리거의 유일한 근거이며, 충분히 **적극적("pushy")**이어야 한다.

좋은 예:
```
"K8s 홈랩 인프라 심층 보안 감사 오케스트레이터. 4명의 감사자 팀… '보안 감사', 'security audit', … 등에 반응. 단일 파일 리뷰는 homelab-ops, 코드 보안은 security-reviewer가 담당한다."
```

핵심 요소:
- 역할 한 문장
- 트리거 키워드 10~20개 (한/영 혼합 허용)
- 비트리거 명시 ("~에는 반응하지 않는다")
- 경계 스킬 병기 (homelab-ops ↔ infra-security-audit 등)

---

## 6. 오케스트레이터 스킬 필수 섹션

오케스트레이터 스킬(`SKILL.md`)은 다음 6개 섹션을 반드시 포함한다:

| 섹션 | 내용 |
|------|------|
| `## 실행 모드` | 서브 에이전트 / 에이전트 팀 / 파이프라인 중 선택 + 이유 |
| `## 에이전트 풀` | subagent_type, model, 역할, 출력 경로를 표로 |
| `## 워크플로우` | Phase별 Agent 호출 + 데이터 전달 방식 |
| `## 에러 핸들링` | 실패 케이스별 대응 (재시도 1회 → 부분 결과) |
| `## 데이터 흐름` | Mermaid 다이어그램 권장 |
| `## 테스트 시나리오` | 정상 흐름 1 + 에러 흐름 1 이상 |

**Agent 호출 시 반드시 포함**: `model: "opus"` — 추론 품질을 일정 수준 이상으로 유지.

---

## 7. 오케스트레이터 간 경계 선언

중복 라우팅을 막기 위해 각 오케스트레이터 description 말미에 경계 스킬을 언급한다.

| 이 스킬 | 경계 선언 |
|---------|---------|
| `homelab-ops` | "새 앱 전체 라이프사이클은 app-lifecycle, 심층 보안 감사는 infra-security-audit이 처리한다" |
| `app-lifecycle` | "기존 앱 매니페스트 수정·트러블슈팅은 homelab-ops가 처리한다" |
| `infra-security-audit` | "빠른 일반 보안 리뷰는 homelab-ops, 코드 보안은 security-reviewer 에이전트가 담당한다" |
| `code-review` | "단순 린팅/포매팅에는 트리거하지 않는다" |
| `runbook-gen` | "장애 대응은 cluster-diagnose, 매니페스트 수정은 homelab-ops가 담당한다" |
| `resource-optimizer` | "매니페스트 생성은 k8s-manifest-generator, 보안 감사는 infra-security-audit" |
| `monitoring-ops` | "단순 kubectl 명령이나 매니페스트 수정에는 트리거하지 않는다" |

---

## 8. 프로젝트 컨벤션 주입 패턴

에이전트가 프로젝트 특유 컨벤션(GitOps, ArgoCD selfHeal, 라벨 4종 등)을 따르게 하려면 프롬프트에 **참조 경로를 주입**한다.

표준 참조 경로:
- `/Users/ukyi/homelab/.claude/skills/homelab-ops/references/project-conventions.md` — 프로젝트 전반 컨벤션
- `/Users/ukyi/homelab/.claude/skills/infra-security-audit/references/severity-criteria.md` — 보안 심각도 분류
- `/Users/ukyi/homelab/.claude/skills/gha-cicd/references/workflow-patterns.md` — GHA 패턴
- `/Users/ukyi/homelab/.claude/skills/runbook-gen/references/runbook-template.md` — Runbook 서식

---

## 9. 글로벌 스킬 활용

프로젝트 `.claude/skills/`에는 프로젝트 특유 스킬만 둔다. 공용 스킬은 글로벌 `~/.claude/skills/`에서 자동 로드된다.

**글로벌에서 자동 로드되는 공용 스킬**:
- `brainstorming` — 창의 작업 전 요구사항 탐색
- `cloudflare` — Cloudflare 플랫폼 (Workers, Tunnel, R2 등)
- `k8s-manifest-generator` — 일반 K8s 매니페스트 생성
- `k8s-security-policies` — NetworkPolicy, RBAC, PSP
- `orbstack-best-practices` — OrbStack 운영 패턴
- `using-superpowers` — 대화 시작 시 스킬 활성화 규칙
- `writing-plans` — 사전 계획서 작성
- `finishing-a-development-branch` — 브랜치 머지 의사결정
- `humanizer` — AI 문체 자연화

프로젝트에서 override가 필요하면 오버라이드 사유를 SKILL.md에 주석으로 남긴다.

---

## 10. 설정 파일

| 파일 | 용도 | git |
|------|------|-----|
| `.claude/settings.json` | 팀 공유 설정 (훅, 권한 등) | 커밋 |
| `.claude/settings.local.json` | 개인 로컬 설정 (허용 명령어 등) | gitignore |

**원칙**: `settings.json`은 최소화. 훅은 프로젝트 전체 수준에서 꼭 필요한 것만 추가한다. 사용자 개인 권한 허용(`Bash(git *)` 등)은 `settings.local.json`으로 분리한다.

---

## 11. 변경 이력 관리

- 스킬 frontmatter의 `version` 필드로 semantic versioning 추적
- breaking change (description/워크플로우 대폭 변경) → major 증가
- 기능 추가 (새 에이전트, 새 phase) → minor 증가
- 오타·문구 정리 → patch 증가

---

## 12. 리뷰 주기

`.claude/` 디렉토리는 6개월마다 감사한다. 감사 체크리스트:

- [ ] 고아 에이전트(어느 오케스트레이터에서도 호출되지 않는) 존재 여부
- [ ] 중복 스킬(글로벌과 100% 동일) 여부 — `diff -q`로 확인
- [ ] `SKILL.md` 파일명 대문자 일관성
- [ ] 에이전트 frontmatter 필수 필드(name, description, model, color) 커버리지
- [ ] description의 트리거 키워드 실제 사용률(사용자 로그 기반)
- [ ] 오케스트레이터 간 라우팅 중복 여부

직전 감사 보고서: `docs/claude-harness-review.md` (2026-04-18)
