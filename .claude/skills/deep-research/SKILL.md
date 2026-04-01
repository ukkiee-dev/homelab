---
name: deep-research
description: "어떤 주제든 웹/학술/커뮤니티 3개 각도에서 병렬 조사하고, 교차 검증 후 종합 보고서를 작성하는 리서치 오케스트레이터. '리서치', '조사해줘', '분석해줘', '알아봐줘', '비교해줘', '현황 파악', '깊게 조사', 'deep research', 'deep dive', '심층 분석', '~에 대해 알려줘', '~의 장단점', '~를 선택해야 하는 이유' 등 주제 조사가 필요한 모든 요청에 반응. 단순 사실 질문('수도가 어디야')이나 코드 작성 요청에는 트리거하지 않는다."
---

# Deep Research — 리서치 오케스트레이터

어떤 주제든 3개 전문 에이전트로 병렬 조사하고, 교차 검증하여 종합 보고서를 산출한다.

## 실행 모드: 서브 에이전트 (Sub-agent, Fan-out/Fan-in)

3명의 연구원이 독립적으로 조사하고, 오케스트레이터가 결과를 수집·교차 검증·종합한다.

## 에이전트 풀

| 에이전트 | subagent_type | 모델 | 조사 영역 |
|---------|--------------|------|----------|
| `web-researcher` | web-researcher | opus | 웹, 뉴스, 공식 문서, 블로그 |
| `academic-researcher` | academic-researcher | opus | 논문, 연구 보고서, 기술 백서 |
| `community-researcher` | community-researcher | opus | Reddit, HN, 포럼, SNS, 실사용 경험 |

## 워크플로우

### Phase 1: 준비

1. 사용자 요청에서 **조사 주제**와 **핵심 질문**을 추출한다
2. 조사 범위를 설정한다 (시간 범위, 지역, 깊이)
3. `_workspace/00_input/` 에 리서치 브리프를 저장한다

```markdown
# 리서치 브리프
- **주제**: ...
- **핵심 질문**: (3-5개)
- **범위**: 시간/지역/깊이
- **제외 항목**: (있으면)
```

### Phase 2: 병렬 조사 (Fan-out)

3개 에이전트를 **동시에** 스폰한다. 모든 Agent 호출에 `model: "opus"` 필수.

```
Agent(
  subagent_type: "web-researcher",
  model: "opus",
  run_in_background: true,
  prompt: "주제: [주제]\n핵심 질문: [질문들]\n범위: [범위]\n
  조사 결과를 _workspace/01_web_findings.md에 저장하라.
  에이전트 정의(.claude/agents/web-researcher.md)의 출력 형식을 따르라."
)

Agent(
  subagent_type: "academic-researcher",
  model: "opus",
  run_in_background: true,
  prompt: "주제: [주제]\n핵심 질문: [질문들]\n범위: [범위]\n
  조사 결과를 _workspace/02_academic_findings.md에 저장하라.
  에이전트 정의(.claude/agents/academic-researcher.md)의 출력 형식을 따르라."
)

Agent(
  subagent_type: "community-researcher",
  model: "opus",
  run_in_background: true,
  prompt: "주제: [주제]\n핵심 질문: [질문들]\n범위: [범위]\n
  조사 결과를 _workspace/03_community_findings.md에 저장하라.
  에이전트 정의(.claude/agents/community-researcher.md)의 출력 형식을 따르라."
)
```

### Phase 3: 교차 검증

3개 조사 결과를 읽고 교차 검증한다:

1. **합의점 추출**: 2개 이상의 소스에서 확인된 주장 → **확인됨 (Confirmed)**
2. **단일 소스 주장**: 1개 소스에서만 나온 주장 → **미검증 (Unverified)**
3. **상충 발견**: 소스 간 모순되는 주장 → **논쟁 중 (Disputed)** + 양쪽 근거 병기
4. **공식 vs 현실 괴리**: 웹(공식 발표)과 커뮤니티(실사용 경험) 간 괴리 → 별도 표시

검증 결과를 `_workspace/04_cross_verification.md`에 저장한다.

### Phase 4: 종합 보고서 작성

교차 검증 결과를 바탕으로 최종 보고서를 작성한다. `references/report-template.md`의 형식을 따른다.

보고서를 `_workspace/05_final_report.md`에 저장하고, 핵심 내용을 사용자에게 직접 출력한다.

### Phase 5: 정리

- `_workspace/` 보존 (감사 추적용, 삭제 금지)
- 사용자에게 최종 보고서 요약 전달
- 보고서 파일 경로 안내

## 워크스페이스 구조

```
_workspace/
├── 00_input/
│   └── research-brief.md
├── 01_web_findings.md
├── 02_academic_findings.md
├── 03_community_findings.md
├── 04_cross_verification.md
└── 05_final_report.md
```

## 에러 핸들링

| 상황 | 대응 |
|------|------|
| 에이전트 1개 실패 | 나머지 2개 결과로 보고서 작성, 누락 영역 명시 |
| 에이전트 2개 이상 실패 | 사용자에게 알리고 부분 결과 제공 |
| 결과가 너무 빈약 | 검색어를 변경하여 해당 에이전트 1회 재시도 |
| 주제가 너무 광범위 | 사용자에게 범위 축소를 제안 (세부 주제 3개 제시) |
| 모든 소스가 동일 출처 인용 | "독립적 검증 부족" 경고를 보고서에 포함 |

## 테스트 시나리오

### 정상 흐름: 기술 비교 조사
1. **입력**: "Kubernetes vs Docker Swarm 비교 분석해줘"
2. 리서치 브리프 작성 (핵심 질문: 성능, 학습곡선, 생태계, 운영 복잡도)
3. 3개 에이전트 병렬 스폰
4. web: 공식 벤치마크, 비교 기사 수집 / academic: 관련 논문 수집 / community: Reddit/HN 토론 수집
5. 교차 검증: "Kubernetes가 대규모에 적합" → 3개 소스 합의 → Confirmed
6. 종합 보고서 작성 + 사용자 전달

### 에러 흐름: 학술 자료 부족
1. **입력**: "최신 AI 코딩 에이전트 비교 분석해줘"
2. academic-researcher: 관련 논문이 거의 없음 (너무 최근 주제)
3. 보고서에 "학술적 검증이 아직 부족한 분야" 명시
4. 웹 + 커뮤니티 결과 중심으로 보고서 작성, 학술 갭을 별도 섹션으로 기술
