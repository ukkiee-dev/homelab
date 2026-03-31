---
name: infra-security-audit
description: "K8s 홈랩 인프라 보안 감사 오케스트레이터. 네트워크(NetworkPolicy, 포트, Traefik), 시크릿(SealedSecret, 평문, 로테이션), 컨테이너(CVE, securityContext, 권한), 접근제어(RBAC, ServiceAccount, Tailscale) 4개 영역을 병렬 감사하고 통합 보안 보고서를 생성한다. '보안 감사', 'security audit', '인프라 보안', '클러스터 보안 점검', '보안 스캔', 'NetworkPolicy 감사', 'RBAC 감사', '시크릿 감사', '컨테이너 보안', '접근제어 점검', '보안 보고서', 'CVE 스캔', '취약점 감사', '보안 현황' 등 인프라 보안 감사 요청에 반응. 코드 보안 리뷰(OWASP, XSS, SQL 인젝션)에는 트리거하지 않는다 — 코드 보안은 security-reviewer 에이전트가 담당."
---

# Infra Security Audit — 인프라 보안 감사 오케스트레이터

K8s 홈랩 인프라를 네트워크·시크릿·컨테이너·접근제어 4개 축에서 병렬 감사하고, 교차 검증을 거쳐 통합 보안 보고서를 생성한다.

## 실행 모드: 에이전트 팀

4명의 감사자가 병렬로 작업하며 교차 도메인 발견을 실시간 공유한다. 한 감사자의 발견이 다른 감사자의 조사 방향을 수정할 수 있어 단독 감사 대비 품질이 크게 향상된다.

## 에이전트 구성

| 팀원 | 에이전트 타입 | 감사 영역 | 출력 |
|------|-------------|----------|------|
| `network-auditor` | network-auditor | NetworkPolicy, 포트, Traefik, Tunnel | `_workspace/audit_network.md` |
| `secret-auditor` | secret-auditor | SealedSecret, 평문, 로테이션, 참조 | `_workspace/audit_secrets.md` |
| `container-auditor` | container-auditor | CVE, securityContext, 권한, 리소스 | `_workspace/audit_containers.md` |
| `access-auditor` | access-auditor | RBAC, ServiceAccount, Tailscale, ArgoCD | `_workspace/audit_access.md` |

## 워크플로우

### Phase 1: 준비
1. 사용자 입력 분석 — 감사 범위 파악 (전체 클러스터 / 특정 네임스페이스 / 특정 영역)
2. `_workspace/` 디렉토리 생성
3. 감사 범위를 `_workspace/00_scope.md`에 저장

### Phase 2: 팀 구성

팀 생성:
```
TeamCreate(
  team_name: "security-audit-team",
  members: [
    { name: "network-auditor", agent_type: "network-auditor", model: "opus",
      prompt: "클러스터 네트워크 보안을 감사하라. 범위: [scope]. 프로젝트 컨벤션은 .claude/skills/homelab-ops/references/project-conventions.md를 참조. 심각도 분류는 .claude/skills/infra-security-audit/references/severity-criteria.md를 참조. 결과를 _workspace/audit_network.md에 저장하라." },
    { name: "secret-auditor", agent_type: "secret-auditor", model: "opus",
      prompt: "클러스터 시크릿 보안을 감사하라. 범위: [scope]. 프로젝트 컨벤션은 .claude/skills/homelab-ops/references/project-conventions.md를 참조. 심각도 분류는 .claude/skills/infra-security-audit/references/severity-criteria.md를 참조. 결과를 _workspace/audit_secrets.md에 저장하라." },
    { name: "container-auditor", agent_type: "container-auditor", model: "opus",
      prompt: "클러스터 컨테이너 보안을 감사하라. 범위: [scope]. 프로젝트 컨벤션은 .claude/skills/homelab-ops/references/project-conventions.md를 참조. 심각도 분류는 .claude/skills/infra-security-audit/references/severity-criteria.md를 참조. 결과를 _workspace/audit_containers.md에 저장하라." },
    { name: "access-auditor", agent_type: "access-auditor", model: "opus",
      prompt: "클러스터 접근제어를 감사하라. 범위: [scope]. 프로젝트 컨벤션은 .claude/skills/homelab-ops/references/project-conventions.md를 참조. 심각도 분류는 .claude/skills/infra-security-audit/references/severity-criteria.md를 참조. 결과를 _workspace/audit_access.md에 저장하라." }
  ]
)
```

작업 등록:
```
TaskCreate(tasks: [
  { title: "네트워크 보안 감사", description: "NetworkPolicy, 포트, Traefik, Tunnel 감사", assignee: "network-auditor" },
  { title: "시크릿 보안 감사", description: "SealedSecret, 평문, 로테이션 감사", assignee: "secret-auditor" },
  { title: "컨테이너 보안 감사", description: "CVE, securityContext, 권한 감사", assignee: "container-auditor" },
  { title: "접근제어 감사", description: "RBAC, ServiceAccount, Tailscale 감사", assignee: "access-auditor" }
])
```

### Phase 3: 병렬 감사 수행

**실행 방식:** 팀원들이 자체 조율

팀원들은 독립적으로 감사를 수행하며, 교차 도메인 발견 시 SendMessage로 공유한다:

**교차 검증 경로:**
| 발신 | 수신 | 상황 |
|------|------|------|
| network → container | 노출 포트 발견 → 해당 컨테이너 보안 설정 확인 |
| container → network | 특권 컨테이너 발견 → 네트워크 격리 확인 |
| secret → access | 평문 시크릿 발견 → 접근 가능 SA 범위 확인 |
| access → secret | 과다 권한 SA 발견 → 접근 가능 시크릿 범위 확인 |
| container → secret | readOnlyRootFilesystem 미설정 + 시크릿 마운트 → 시크릿 유출 경로 |
| access → network | NetworkPolicy 수정 권한 SA → 네트워크 격리 우회 가능성 |

**산출물 저장:**
| 팀원 | 출력 경로 |
|------|----------|
| network-auditor | `_workspace/audit_network.md` |
| secret-auditor | `_workspace/audit_secrets.md` |
| container-auditor | `_workspace/audit_containers.md` |
| access-auditor | `_workspace/audit_access.md` |

**리더 모니터링:**
- 팀원이 유휴 상태가 되면 자동 알림 수신
- TaskGet으로 전체 진행률 확인
- 특정 팀원이 막혔을 때 SendMessage로 지원

### Phase 4: 통합 보안 보고서 생성

1. 4개 산출물을 Read로 수집
2. 교차 관심사(cross-cutting concerns) 식별:
   - 네트워크 노출 + 컨테이너 취약점 = 공격 체인
   - 과다 권한 SA + 시크릿 접근 = 권한 상승 경로
   - 특권 컨테이너 + 네트워크 미격리 = 래터럴 무브먼트
3. 심각도별 정렬: Critical → High → Medium → Low
4. 통합 보고서 생성 (아래 형식)
5. 사용자에게 결과 전달

**통합 보고서 형식:**
```markdown
# 인프라 보안 감사 보고서

**감사 일시**: YYYY-MM-DD
**감사 범위**: [전체 클러스터 / 특정 범위]
**감사자**: network-auditor, secret-auditor, container-auditor, access-auditor

## 요약 대시보드
| 심각도 | 네트워크 | 시크릿 | 컨테이너 | 접근제어 | 합계 |
|--------|---------|--------|---------|---------|------|
| Critical | N | N | N | N | N |
| High | N | N | N | N | N |
| Medium | N | N | N | N | N |
| Low | N | N | N | N | N |

## 교차 도메인 위험 (Attack Chains)
[2개 이상 영역에 걸친 복합 위험]

## Critical 발견 사항
[즉시 조치 필요]

## High 발견 사항
[1주 내 조치 권장]

## Medium 발견 사항
[1개월 내 조치 권장]

## Low 발견 사항
[개선 권장]

## Remediation 가이드
[심각도별 구체적 수정 절차]

## 권고사항
[장기 개선 방향]
```

### Phase 5: 정리
1. 팀원들에게 종료 요청 (SendMessage)
2. 팀 정리
3. `_workspace/` 보존 (감사 추적용)
4. 사용자에게 보고서 요약 전달

## 데이터 흐름

```
[리더] → TeamCreate → [network] ←SendMessage→ [container]
                       [secret]  ←SendMessage→ [access]
                          │                        │
                          ↓                        ↓
                   audit_network.md          audit_access.md
                   audit_secrets.md          audit_containers.md
                          │                        │
                          └──────── Read ──────────┘
                                    ↓
                            [리더: 통합 보고서]
                                    ↓
                        통합 보안 감사 보고서
```

## 에러 핸들링

| 상황 | 전략 |
|------|------|
| 감사자 1명 실패 | SendMessage로 상태 확인 → 재시작 시도. 재실패 시 해당 영역 "미감사" 명시 |
| 감사자 과반 실패 | 사용자에게 알리고 진행 여부 확인 |
| kubectl 접근 불가 | 전 감사자에게 "정적 분석 모드"로 전환 지시 |
| 교차 검증 데이터 상충 | 양쪽 출처를 병기, 삭제하지 않음 |
| 타임아웃 | 현재까지 수집된 부분 결과로 보고서 생성, 미완료 영역 명시 |

## 기존 스킬/에이전트 연동

| 리소스 | 연동 방식 |
|--------|----------|
| `k8s-security-policies` 스킬 | 감사자가 RBAC/NetworkPolicy 참조 기준으로 Read |
| `infra-reviewer` 에이전트 | 감사 체크리스트의 기반. 직접 호출하지 않고 에이전트 정의를 참고 |
| `project-conventions.md` | 모든 감사자의 프로젝트 기준 — 프롬프트에 경로 포함 |

## 테스트 시나리오

### 정상 흐름: 전체 클러스터 감사
1. **입력**: "클러스터 보안 전체 감사해줘"
2. Phase 1: 범위 = 전체 클러스터
3. Phase 2: 4명 팀 구성 + 4개 작업 등록
4. Phase 3: 4명 병렬 감사, 교차 검증 수행
   - network: default-deny 확인, 미들웨어 누락 탐지
   - secret: SealedSecret 무결성, 평문 Grep
   - container: securityContext 전수 검사, 이미지 목록화
   - access: RBAC wildcard 탐지, SA 토큰 마운트 검사
5. Phase 4: 4개 결과 통합, 교차 도메인 위험 식별, 보고서 생성
6. Phase 5: 팀 정리, 사용자에게 요약 전달
7. 예상 결과: `_workspace/` 하위 감사 파일 4개 + 통합 보고서

### 에러 흐름: kubectl 미접근
1. Phase 3에서 kubectl 명령 실패
2. 리더가 전 팀원에게 "정적 분석 모드 전환" SendMessage
3. 팀원들이 매니페스트 파일만으로 감사 수행
4. 보고서에 "정적 분석 모드 — 라이브 클러스터 미검증" 명시
5. 이미지 CVE 스캔 영역은 "미감사"로 표시
