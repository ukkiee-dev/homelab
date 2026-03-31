---
name: monitoring-ops
description: "모니터링·옵저버빌리티 오케스트레이터. 새 앱 모니터링 설정 생성(대시보드+알람+쿼리), 알람 튜닝, 쿼리 최적화, 옵저버빌리티 감사를 조율한다. '모니터링 설정', '대시보드 만들어', '알람 추가', '쿼리 최적화', 'PromQL', 'LogsQL', '옵저버빌리티', 'Grafana 설정', 'VictoriaMetrics', '알람 튜닝', '모니터링 감사', '메트릭 추가', '로그 확인' 등 모니터링 관련 모든 요청에 반응. 단순 kubectl 명령이나 매니페스트 수정에는 트리거하지 않는다."
---

# Monitoring Ops — 모니터링 오케스트레이터

4개 전문 에이전트로 모니터링 설정을 병렬 생성하고, 리뷰어가 통합 검증한다.

## 실행 모드: 서브 에이전트 (Fan-out + Producer-Reviewer)

Phase A에서 3명이 병렬 생성, Phase B에서 리뷰어가 통합 검증한다.

## 에이전트 풀

| 에이전트 | 모델 | 역할 |
|---------|------|------|
| `dashboard-designer` | opus | Grafana 대시보드 JSON 설계·생성 |
| `alert-engineer` | opus | 알람 규칙 작성, 임계값, Telegram 라우팅 |
| `query-optimizer` | opus | PromQL/LogsQL 작성·최적화 |
| `observability-reviewer` | opus | 메트릭·로그·알람·대시보드 통합 검증 |

## 워크플로우

### Phase 1: 입력 분석

사용자 요청을 분류한다:

| 유형 | 트리거 예시 | 투입 에이전트 | 패턴 |
|------|-----------|-------------|------|
| **새 앱 모니터링** | "이 앱 모니터링 설정해줘" | 4명 전원 | Fan-out→Review |
| **대시보드만** | "대시보드 만들어줘" | dashboard-designer + query-optimizer | 순차 |
| **알람만** | "알람 추가해줘", "임계값 조정" | alert-engineer + query-optimizer | 순차 |
| **쿼리만** | "PromQL 작성해줘", "쿼리 최적화" | query-optimizer | 단독 |
| **모니터링 감사** | "모니터링 빠진 거 없나" | observability-reviewer | 단독 |
| **종합 튜닝** | "전체 알람 재검토" | alert-engineer + observability-reviewer | 순차 |

### Phase 2A: 병렬 생성 (새 앱 모니터링 시)

앱 정보(이름, 네임스페이스, 포트, 메트릭 엔드포인트 유무)를 수집한 뒤 3개 에이전트를 동시에 스폰한다.

```
Agent(dashboard-designer, run_in_background=true,
  prompt: "앱: [앱명], ns: [네임스페이스], 포트: [포트]
  메트릭 엔드포인트: [있음/없음]
  에이전트 정의를 읽고 대시보드 JSON + 요약을 _workspace/에 저장하라.")

Agent(alert-engineer, run_in_background=true,
  prompt: "앱: [앱명], ns: [네임스페이스]
  기존 알람 규칙: manifests/monitoring/grafana/alerting.yaml 참조
  에이전트 정의를 읽고 앱 전용 알람 규칙 YAML + 요약을 _workspace/에 저장하라.")

Agent(query-optimizer, run_in_background=true,
  prompt: "앱: [앱명], ns: [네임스페이스], 포트: [포트]
  대시보드와 알람에 사용할 PromQL/LogsQL 쿼리를 설계하라.
  에이전트 정의를 읽고 쿼리 목록을 _workspace/에 저장하라.")
```

### Phase 2B: 통합 검증

3개 산출물이 완료되면 리뷰어를 스폰한다:

```
Agent(observability-reviewer, model: "opus",
  prompt: "_workspace/ 의 01~03 파일과 앱 매니페스트를 읽고
  메트릭·로그·알람·대시보드 완성도를 종합 검증하라.
  에이전트 정의의 체크리스트를 따르고 결과를 _workspace/04_observability_review.md에 저장하라.")
```

### Phase 3: 결과 통합

리뷰어 결과를 읽고:
1. **FAIL 항목**: 해당 에이전트를 재호출하여 수정 (최대 1회)
2. **PASS**: 산출물을 사용자에게 전달
3. **통합 보고서** 작성: 대시보드 JSON, 알람 YAML, 적용 방법을 정리

### Phase 4: 적용 안내

산출물의 실제 적용 방법을 안내한다:

- **대시보드**: Grafana UI에서 Import (JSON 파일) 또는 API 호출
- **알람**: `manifests/monitoring/grafana/alerting.yaml` ConfigMap에 규칙 추가 → git push → ArgoCD 자동 동기화
- **scrape annotation**: 앱 Deployment에 annotation 추가 → git push

## 워크스페이스 구조

```
_workspace/
├── 00_input/
│   └── app-info.md
├── 01_dashboard.json
├── 01_dashboard_summary.md
├── 02_alerting.yaml
├── 02_alert_summary.md
├── 03_queries.md
└── 04_observability_review.md
```

## 에러 핸들링

| 상황 | 대응 |
|------|------|
| 에이전트 실패 | 1회 재시도, 재실패 시 해당 영역 누락 명시 |
| 앱에 메트릭 없음 | 컨테이너 기본 메트릭(CPU/Memory)만으로 최소 구성, 커스텀 메트릭 추가 방법 안내 |
| 리뷰 FAIL 다수 | 에이전트 재호출 1회 후에도 FAIL이면 사용자에게 수동 검토 요청 |
| 기존 알람과 충돌 | 기존 규칙 UID 확인 후 중복 방지 |

## 테스트 시나리오

### 정상 흐름: 새 앱 모니터링 설정
1. **입력**: "test-app에 모니터링 설정해줘. 네임스페이스: test-app, 포트: 3000, 메트릭 엔드포인트 없음"
2. 3개 에이전트 병렬 스폰 (dashboard + alert + query)
3. dashboard-designer: 기본 패널 6개 (CPU, Memory, Pod 상태, 재시작, 네트워크, 에러 로그)
4. alert-engineer: 앱 전용 알람 2개 (health check 실패, 에러 로그 급증)
5. query-optimizer: 대시보드/알람용 PromQL 8개 + LogsQL 2개
6. observability-reviewer: 5개 영역 검증 → 전체 PASS
7. 통합 보고서 + 적용 방법 안내

### 에러 흐름: 리뷰 FAIL
1. **입력**: "immich 모니터링 강화해줘"
2. 3개 에이전트 병렬 → 리뷰어 검증
3. 리뷰어: 알람 커버리지 FAIL (백업 CronJob 실패 알람 누락)
4. alert-engineer 재호출 → 백업 실패 알람 추가
5. 리뷰어 재검증 → PASS
6. 최종 보고서 전달
