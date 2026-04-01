---
name: app-lifecycle
description: "홈랩 앱 라이프사이클 오케스트레이터. 아이디어 → 설계 → 프로비저닝 → 검증 → 운영 → 폐기까지 전체 사이클을 조율한다. '새 앱 추가', '앱 올려줘', '서비스 배포', '앱 설계', '프로비저닝', '검증해줘', '앱 제거', '서비스 종료', 'teardown', '폐기', '앱 라이프사이클', '전체 배포 프로세스', '새 서비스 셋업' 등 앱의 생성부터 폐기까지 전체 라이프사이클 관리 요청에 반응. 단순 매니페스트 수정이나 트러블슈팅에는 트리거하지 않는다 — 그런 요청은 homelab-ops가 처리한다."
---

# App Lifecycle — 라이프사이클 오케스트레이터

홈랩 앱의 전체 라이프사이클(설계 → 프로비저닝 → 검증 → 폐기)을 전문 에이전트에게 라우팅하고, 단계 간 데이터를 전달하며, 최종 결과를 종합한다.

## 실행 모드: 서브 에이전트 + 감독자 패턴

라이프사이클 단계는 순차적이고 에이전트 간 실시간 통신이 필요 없다. 감독자(오케스트레이터)가 요청을 분석하여 적절한 에이전트를 동적으로 호출하고, 이전 단계의 결과를 다음 단계에 전달한다.

## 에이전트 풀

| 에이전트 | subagent_type | 모델 | 라이프사이클 단계 |
|---------|--------------|------|----------------|
| `app-architect` | app-architect | opus | 설계 (Design) |
| `provisioning-engineer` | provisioning-engineer | opus | 프로비저닝 (Provision) |
| `verification-agent` | verification-agent | opus | 검증 (Verify) |
| `decommission-manager` | decommission-manager | opus | 폐기 (Decommission) |

기존 에이전트 연동:
| 에이전트 | 연동 방식 |
|---------|----------|
| `manifest-engineer` | provisioning-engineer가 참고하는 패턴 소스 |
| `cluster-ops` | verification-agent/decommission-manager가 런타임 진단 시 위임 |
| `infra-reviewer` | 복잡한 네트워크/보안 설정 사전 검토 시 호출 |

## 워크플로우

### Step 0: 요청 분석

사용자 요청을 라이프사이클 액션으로 분류한다:

| 액션 | 트리거 예시 | 투입 에이전트 | 패턴 |
|------|-----------|-------------|------|
| **신규 배포** | "이 앱 올려줘", "새 서비스 추가" | architect → provisioner → verifier | 파이프라인 |
| **설계만** | "이 앱 어떻게 배포하면 좋을까" | architect | 단독 |
| **프로비저닝만** | "설계는 됐고 매니페스트 만들어줘" | provisioner → verifier | 순차 |
| **검증만** | "배포한 거 제대로 떴나 확인해줘" | verifier | 단독 |
| **폐기** | "이 앱 내려줘", "서비스 종료" | decommissioner | 단독 |
| **재배포** | "앱 설정 바꿔서 다시 올려줘" | provisioner → verifier | 순차 |

### Step 1: 에이전트 호출

**모든 Agent 호출에 `model: "opus"` 필수.**

#### 신규 배포 파이프라인 (전체 라이프사이클)

```
Phase 1: 설계
  Agent(
    subagent_type: "app-architect",
    model: "opus",
    prompt: "사용자 요청 + 프로젝트 컨텍스트"
  )
  → 산출: 설계 문서

Phase 2: 사용자 확인
  → 설계 문서를 사용자에게 보여주고 승인/수정 요청
  → 승인되면 Phase 3으로

Phase 3: 프로비저닝
  Agent(
    subagent_type: "provisioning-engineer",
    model: "opus",
    prompt: "확정된 설계 문서"
  )
  → 산출: 생성된 파일 목록

Phase 4: 검증
  Agent(
    subagent_type: "verification-agent",
    model: "opus",
    prompt: "앱 이름 + 네임스페이스 + 설계 문서"
  )
  → 산출: 검증 보고서

Phase 5: 결과 종합
  → 검증 PASS: 배포 완료 보고
  → 검증 WARN: 경고 사항과 함께 보고
  → 검증 FAIL: provisioning-engineer 재호출하여 수정 후 재검증 (최대 1회)
```

#### 폐기 플로우

```
Phase 1: 영향 분석
  Agent(
    subagent_type: "decommission-manager",
    model: "opus",
    prompt: "앱 이름 + 제거 이유"
  )
  → 산출: 제거 계획

Phase 2: 사용자 확인
  → 제거 계획을 사용자에게 보여주고 최종 승인 요청
  → 특히 되돌릴 수 없는 작업(GHCR 삭제, PVC 데이터 삭제)을 강조

Phase 3: 실행
  → 승인 시 teardown 워크플로우 트리거 방법 안내
  → 또는 수동 제거 단계 실행
```

### Step 2: 데이터 전달

에이전트 간 데이터 전달은 **프롬프트 기반**으로 수행한다:
- 이전 에이전트의 산출물(설계 문서, 파일 목록, 검증 보고서)을 다음 에이전트 프롬프트에 포함
- 대용량 산출물은 파일 경로만 전달하고 에이전트가 직접 읽도록 지시

### Step 3: 결과 종합

**단독 액션**: 에이전트 결과를 사용자에게 직접 전달
**파이프라인 액션**: 각 Phase 결과를 종합하여:
- 전체 라이프사이클 진행 상황 요약
- 생성/수정된 파일 목록
- 검증 결과 (PASS/WARN/FAIL)
- 후속 작업 안내 (SealedSecret 생성, CI 트리거, 모니터링 대시보드 추가 등)

## homelab-ops와의 역할 분담

| 요청 유형 | 담당 | 이유 |
|----------|------|------|
| 새 앱 배포 (처음부터) | **app-lifecycle** | 설계 → 프로비저닝 → 검증 전체 체인 |
| 앱 폐기 | **app-lifecycle** | 의존성 분석 → 안전 제거 |
| 기존 앱 매니페스트 수정 | homelab-ops | 프로비저닝 체인 불필요 |
| 트러블슈팅 | homelab-ops | 진단 → 수정 흐름 |
| 인프라 리뷰/감사 | homelab-ops | 운영 시점 검토 |
| 클러스터 전체 점검 | homelab-ops | 운영 모니터링 |

## 에러 핸들링

| 상황 | 대응 |
|------|------|
| 에이전트 실패 | 에러 분석 후 프롬프트 수정하여 1회 재시도 |
| 재실패 | 해당 Phase 결과 없이 진행, 누락을 사용자에게 명시 |
| 설계-프로비저닝 불일치 | provisioning-engineer에게 설계 문서 재전달하여 수정 |
| 검증 실패 | 실패 항목을 provisioning-engineer에게 전달하여 수정 후 재검증 (최대 1회) |
| 사용자 거절 | 해당 Phase에서 중단하고 사유를 기록 |

## 프로젝트 레퍼런스

에이전트 프롬프트에 아래 파일 경로를 포함하여 컨벤션 준수를 보장하라:
- 프로젝트 컨벤션: `.claude/skills/homelab-ops/references/project-conventions.md`
- 기존 앱 구조: `manifests/apps/` 하위 디렉토리
- 앱 레지스트리: `terraform/apps.json`
- Teardown 워크플로우: `.github/workflows/teardown.yml`
- Setup action: `.github/actions/setup-app/action.yml`

## 테스트 시나리오

### 정상 흐름: 신규 앱 배포

1. **입력**: "Next.js 블로그 앱 올려줘. 이미지 ghcr.io/ukkiee-dev/my-blog:latest, public 접근, 포트 3000"
2. app-architect: 앱 유형=web, 리소스=100m/200m CPU + 128Mi/256Mi Mem, entryPoint=web, 네임스페이스=apps, 서브도메인=blog
3. 사용자 승인
4. provisioning-engineer: apps.json 추가, 매니페스트 5종 생성, ArgoCD Application 생성
5. verification-agent: 정적 분석 PASS (라벨, 포트, 보안 컨텍스트, ArgoCD 설정 모두 정상)
6. 최종 보고: 생성 파일 목록 + 후속 작업 (git push → ArgoCD 자동 동기화)

### 정상 흐름: 앱 폐기

1. **입력**: "test-app 내려줘"
2. decommission-manager: 의존성 없음, PVC 없음, DNS+Tunnel+GHCR 리소스 존재
3. 제거 계획 제시 + 사용자 확인 요청
4. 사용자 승인 → teardown 워크플로우 트리거 안내: `gh workflow run teardown.yml -f app-name=test-app`

### 에러 흐름: 검증 실패

1. 신규 배포 Phase 4에서 verification-agent가 포트 불일치 발견 (FAIL)
2. 실패 항목을 provisioning-engineer에게 전달
3. provisioning-engineer가 Service targetPort 수정
4. 재검증 → PASS
5. 수정 이력 포함하여 최종 보고
