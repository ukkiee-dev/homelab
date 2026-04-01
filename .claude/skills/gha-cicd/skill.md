---
name: gha-cicd
description: "GitHub Actions CI/CD 오케스트레이터. 워크플로우 작성, 복합 액션 설계, 파이프라인 리뷰(보안/효율/비용), 실패 분석, 테스트 전략 설계를 전문 에이전트에 라우팅한다. 'workflow', '워크플로우', 'GHA', 'GitHub Actions', 'CI/CD', '파이프라인', '복합 액션', 'composite action', 'reusable workflow', '자동화 추가', '빌드 실패', 'CI 에러', '러너 문제', '워크플로우 테스트', '드라이런', 'Actions 리뷰', '파이프라인 보안' 등 GitHub Actions 관련 모든 요청에 반응. 단순 git 명령이나 GitHub API 직접 호출 같은 Actions와 무관한 작업에는 트리거하지 않는다."
---

# GHA CI/CD — 파이프라인 오케스트레이터

GitHub Actions 워크플로우의 작성·리뷰·디버깅·테스트를 전문 에이전트에 라우팅하고 결과를 종합한다.

## 실행 모드: 서브 에이전트

파이프라인 패턴(빌더→리뷰어→테스터)은 순차 의존이 강하고, 디버거는 실패 시에만 호출하는 전문가 풀이므로 서브 에이전트가 적합하다.

## 에이전트 구성

| 에이전트 | subagent_type | 역할 | 스킬/레퍼런스 | 출력 |
|---------|--------------|------|-------------|------|
| `workflow-builder` | workflow-builder | GHA YAML 작성 | workflow-patterns.md | `.github/` 하위 YAML |
| `pipeline-reviewer` | pipeline-reviewer | 보안/효율/비용 감사 | review-checklist.md | 리뷰 리포트 |
| `workflow-tester` | workflow-tester | 테스트 전략 설계 | — | 테스트 계획서 |
| `pipeline-debugger` | pipeline-debugger | 실패 분석 | debug-playbook.md | 근본 원인 + 수정 제안 |

## 워크플로우

### 1단계: 작업 유형 판별

사용자 요청을 아래 유형으로 분류한다:

| 유형 | 트리거 예시 | 투입 에이전트 | 패턴 |
|------|-----------|-------------|------|
| **워크플로우 생성** | "워크플로우 만들어", "자동화 추가" | builder → reviewer → tester | 파이프라인 |
| **워크플로우 수정** | "이 워크플로우 고쳐", "스텝 추가해" | builder → reviewer | 순차 |
| **파이프라인 리뷰** | "CI 보안 점검", "워크플로우 감사" | reviewer | 단독 |
| **실패 분석** | "빌드 깨짐", "왜 실패했어" | debugger | 단독 |
| **실패 후 수정** | 디버거 분석 결과 수정 필요 | debugger → builder → reviewer | 순차 |
| **테스트 설계** | "워크플로우 테스트 계획" | tester | 단독 |
| **종합 감사** | "전체 CI/CD 점검" | reviewer(모든 워크플로우) | 단독 (반복) |

### 2단계: 에이전트 실행

**모든 Agent 호출에 `model: "opus"` 필수.**

#### 파이프라인 실행 (워크플로우 생성)

```
Phase 1: Agent(
  subagent_type: "workflow-builder",
  model: "opus",
  prompt: "워크플로우 YAML 생성: ..."
) → _workspace/에 산출물 경로 기록

Phase 2: Agent(
  subagent_type: "pipeline-reviewer",
  model: "opus",
  prompt: "Phase 1 산출물 리뷰: ..."
) → PASS: Phase 3로 진행
  → WARN/FAIL: 리뷰 결과를 담아 workflow-builder 재호출 → 수정 → 재리뷰 (최대 2회)

Phase 3: Agent(
  subagent_type: "workflow-tester",
  model: "opus",
  prompt: "최종 워크플로우에 대한 테스트 계획 수립: ..."
)
```

#### 단독 실행
```
Agent(
  subagent_type: "{agent-name}",
  model: "opus",
  prompt: "<작업 설명>\n<관련 파일 경로>\n<프로젝트 레퍼런스 경로>"
)
```

#### 실패 분석 → 수정
```
Phase 1: Agent(
  subagent_type: "pipeline-debugger",
  model: "opus",
  prompt: "근본 원인 분석: ..."
)
Phase 2: 수정 필요 시 → Agent(
  subagent_type: "workflow-builder",
  model: "opus",
  prompt: "워크플로우 수정: ..."
)
Phase 3: Agent(
  subagent_type: "pipeline-reviewer",
  model: "opus",
  prompt: "수정된 워크플로우 리뷰: ..."
)
```

### 3단계: 결과 종합

**단독 작업**: 에이전트 결과를 사용자에게 전달
**파이프라인 작업**: 각 Phase 결과를 종합하여:
- 생성된 파일 목록
- 리뷰 결과 요약 (critical/warning/info 카운트)
- 테스트 계획 핵심 사항
- 남은 액션 아이템

## 프로젝트 레퍼런스

에이전트 프롬프트에 필요한 레퍼런스 경로를 포함한다:
- 워크플로우 패턴: `.claude/skills/gha-cicd/references/workflow-patterns.md`
- 리뷰 체크리스트: `.claude/skills/gha-cicd/references/review-checklist.md`
- 디버그 플레이북: `.claude/skills/gha-cicd/references/debug-playbook.md`
- 프로젝트 컨벤션: `.claude/skills/homelab-ops/references/project-conventions.md`

## 에러 핸들링

| 상황 | 대응 |
|------|------|
| 에이전트 실패 | 에러 분석 후 프롬프트 수정하여 1회 재시도 |
| 재실패 | 해당 에이전트 없이 진행, 누락 영역을 사용자에게 명시 |
| 리뷰 반복 실패 | 2회 수정 후에도 FAIL이면 사용자에게 리뷰 결과 전달, 판단 위임 |
| 상충 결과 | 삭제하지 않고 양쪽 근거를 병기, 사용자 판단에 맡김 |

## 테스트 시나리오

### 정상 흐름: 새 워크플로우 생성
1. **입력**: "이미지 빌드 후 자동 배포하는 워크플로우 만들어줘"
2. workflow-builder가 `.github/workflows/build-deploy.yml` 생성
3. pipeline-reviewer가 리뷰 → PASS (보안 컨텍스트 충족, 시크릿 안전)
4. workflow-tester가 테스트 계획 수립 (정상/실패/동시실행 시나리오)
5. 결과 종합: 파일 경로 + 리뷰 요약 + 테스트 계획 전달

### 에러 흐름: 실패 분석 → 수정
1. **입력**: "teardown 워크플로우가 실패했어, run ID 12345"
2. pipeline-debugger가 `gh run view 12345 --log-failed` 분석
3. 근본 원인: Terraform state lock (다른 실행과 동시 접근)
4. 수정 필요 → workflow-builder에게 concurrency group 강화 지시
5. pipeline-reviewer가 수정된 워크플로우 리뷰 → PASS
6. 결과 종합: 원인 + 수정 + 리뷰 결과 + 재발 방지책 전달

### 단독 흐름: 전체 감사
1. **입력**: "CI/CD 전체 보안 점검해줘"
2. pipeline-reviewer가 `.github/workflows/` 전체 + `.github/actions/` 리뷰
3. 각 워크플로우별 보안/효율/비용 결과를 심각도별 정렬
4. 통합 감사 보고서 전달
