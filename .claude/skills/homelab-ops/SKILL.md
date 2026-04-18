---
name: homelab-ops
description: "K8s homelab 운영 오케스트레이터. 기존 앱 매니페스트 수정, 클러스터 진단, 인프라 리뷰, 보안 감사 등 homelab 운영 작업을 조율한다. 'homelab', '클러스터 운영', '진단해줘', '리뷰해줘', '감사해줘', '점검해줘', '인프라 변경', '왜 안 되', '매니페스트 수정', '보안 확인', '리소스 늘려줘', '포트 바꿔줘' 등 운영·수정·진단 요청에 반응. 새 앱을 처음부터 설계·배포하거나 앱을 폐기하는 전체 라이프사이클 요청은 app-lifecycle 스킬이 처리한다."
---

# Homelab Ops — 운영 오케스트레이터

이 homelab 프로젝트의 운영 작업을 전문 에이전트에게 라우팅하고 결과를 종합한다.

## 실행 모드: 서브 에이전트 (Sub-agent)

홈랩 운영 작업은 대부분 1-2명의 전문가로 충분하고, 에이전트 간 실시간 토론이 필요한 경우가 드물다. 결과가 사용자에게 직접 돌아가면 된다.

## 에이전트 풀

| 에이전트 | subagent_type | 모델 | 전문 영역 |
|---------|--------------|------|----------|
| `manifest-engineer` | manifest-engineer | opus | 매니페스트 생성/수정/검증, ArgoCD 정의 |
| `cluster-ops` | cluster-ops | opus | 클러스터 진단, 트러블슈팅, 로그 분석 |
| `infra-reviewer` | infra-reviewer | opus | 인프라/보안/성능 종합 리뷰 |

## 워크플로우

### 1단계: 작업 유형 판별

사용자 요청을 아래 유형으로 분류한다:

| 유형 | 트리거 예시 | 투입 에이전트 | 패턴 |
|------|-----------|-------------|------|
| **앱 배포** | "이 앱 배포해줘", "새 서비스 추가" | manifest-engineer → infra-reviewer | 순차 (생성→리뷰) |
| **매니페스트 수정** | "리소스 늘려줘", "포트 바꿔줘" | manifest-engineer | 단독 |
| **트러블슈팅** | "파드 안 뜸", "CrashLoop", "에러 확인" | cluster-ops | 단독 |
| **인프라 리뷰** | "보안 검토해줘", "네트워크 정책 확인" | infra-reviewer | 단독 |
| **종합 감사** | "전체 점검", "클러스터 감사", "헬스체크" | cluster-ops + infra-reviewer | 병렬 |
| **복합 트러블슈팅** | 진단 후 수정 필요 | cluster-ops → manifest-engineer | 순차 |

### 2단계: 에이전트 실행

**모든 Agent 호출에 `model: "opus"` 필수.**

#### 단독 실행
```
Agent(
  subagent_type: "{agent-name}",
  model: "opus",
  prompt: "<작업 설명>\n<관련 파일 경로>\n<추가 컨텍스트>"
)
```

#### 순차 실행 (앱 배포)
```
Phase 1: Agent(
  subagent_type: "manifest-engineer",
  model: "opus",
  prompt: "매니페스트 생성: ..."
) → 매니페스트 생성

Phase 2: Agent(
  subagent_type: "infra-reviewer",
  model: "opus",
  prompt: "생성된 매니페스트 리뷰: ..."
) → 리뷰

Phase 3: 리뷰 피드백 있으면 → manifest-engineer 재호출
```

#### 병렬 실행 (종합 감사)
```
Agent(
  subagent_type: "cluster-ops",
  model: "opus",
  run_in_background: true,
  prompt: "클러스터 상태 진단: 노드/파드/리소스/이벤트"
)
Agent(
  subagent_type: "infra-reviewer",
  model: "opus",
  run_in_background: true,
  prompt: "인프라 종합 리뷰: 보안/네트워킹/모니터링/ArgoCD"
)
→ 두 결과를 종합하여 통합 보고서 작성
```

### 3단계: 결과 종합

**단독 작업**: 에이전트 결과를 사용자에게 전달
**복합/병렬 작업**: 에이전트 결과를 종합하여:
- 발견 사항을 심각도별 정렬 (critical → warning → info)
- 액션 아이템을 우선순위별 정리
- 상충 의견이 있으면 양쪽 출처 병기

## 프로젝트 레퍼런스

프로젝트 고유 컨벤션은 `references/project-conventions.md`에 정리되어 있다. 에이전트 프롬프트에 이 파일의 경로를 포함하여 컨벤션 준수를 보장하라.

## 에러 핸들링

| 상황 | 대응 |
|------|------|
| 에이전트 실패 | 에러 분석 후 프롬프트 수정하여 1회 재시도 |
| 재실패 | 해당 에이전트 없이 진행, 누락 영역을 사용자에게 명시 |
| 상충 결과 | 삭제하지 않고 양쪽 근거를 병기, 사용자 판단에 맡김 |
| 타임아웃 | 부분 결과 활용, 미완료 영역 명시 |

## 테스트 시나리오

### 정상 흐름: 앱 배포
1. **입력**: "Next.js 앱 배포해줘. 이름 my-blog, 이미지 ghcr.io/ukkiee-dev/my-blog:latest, 포트 3000, public 접근"
2. manifest-engineer가 매니페스트 5종 생성 (deployment, service, ingressroute, kustomization, ArgoCD app)
3. infra-reviewer가 리뷰 (보안 컨텍스트, 네트워킹, 리소스 적정성)
4. 리뷰 PASS → 파일 목록 + 주요 설정 요약을 사용자에게 전달
5. 리뷰 WARN/FAIL → manifest-engineer 재호출하여 수정 후 재리뷰

### 에러 흐름: 트러블슈팅 → 수정
1. **입력**: "adguard 파드가 CrashLoopBackOff야"
2. cluster-ops가 진단 (kubectl logs, describe, events 분석)
3. 근본 원인 발견 (예: memory limit 초과)
4. 매니페스트 수정 필요 → manifest-engineer에게 구체적 수정 사항 전달
5. 원인 + 수정 내용 + 재발 방지책을 통합 보고

### 병렬 흐름: 종합 감사
1. **입력**: "클러스터 전체 점검해줘"
2. cluster-ops(배경) + infra-reviewer(배경) 병렬 실행
3. cluster-ops: 노드 리소스, 파드 상태, 이벤트, PVC 사용량 보고
4. infra-reviewer: 보안 정책, 네트워킹, ArgoCD 동기화, 모니터링 커버리지 보고
5. 두 보고서를 심각도별로 종합하여 통합 감사 보고서 작성
