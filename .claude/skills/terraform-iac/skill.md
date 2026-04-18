---
name: terraform-iac
description: "Terraform IaC 관리 오케스트레이터. HCL 코드 작성(dns.tf, apps.json), 인프라 드리프트 탐지(terraform plan 분석), 상태 관리(R2 백엔드, import, state mv)를 전문 에이전트에 라우팅한다. 'terraform', 'HCL', 'dns.tf', 'apps.json 수정', 'DNS 레코드', 'terraform plan', '드리프트', 'drift', 'state 관리', 'terraform import', 'state lock', 'R2 백엔드', 'provider 업그레이드', 'Cloudflare DNS', 'terraform 검증', 'IaC' 등 Terraform 관련 모든 요청에 반응. 단순 Cloudflare Workers/Pages 질문이나 K8s 매니페스트만 필요한 요청에는 트리거하지 않는다."
version: "1.0.0"
---

# Terraform IaC Orchestrator

Terraform IaC 작업을 전문 에이전트에 라우팅하는 오케스트레이터. 생성-검증 패턴으로 코드 변경의 안전성을 보장한다.

## 실행 모드: 서브 에이전트

IaC 엔지니어가 코드를 변경하고, 드리프트 감지자가 plan으로 검증하는 순차 흐름이다. 상태 관리자는 독립적으로 호출한다.

## 에이전트 구성

| 에이전트 | subagent_type | 역할 | 호출 조건 |
|---------|--------------|------|---------|
| IaC 엔지니어 | `iac-engineer` | HCL 작성, apps.json 관리, provider 업그레이드 | Terraform 코드 변경 요청 |
| 드리프트 감지자 | `drift-detector` | plan 분석, 드리프트 탐지, 변경 검증 | 코드 변경 후 검증 또는 독립 드리프트 점검 |
| 상태 관리자 | `state-manager` | R2 상태 건강 확인, 잠금 해결, 마이그레이션 | state 관련 작업 요청 |

## 작업 라우팅

사용자 요청을 분석하여 적절한 워크플로우를 선택한다:

### A. HCL 코드 변경 (생성-검증 패턴)

apps.json 수정, 새 리소스 추가, provider 업그레이드 등 코드 변경이 필요한 요청.

**Phase 1: 코드 생성**
1. `iac-engineer`에게 변경 요청 위임
   ```
   Agent(
     subagent_type: "iac-engineer",
     model: "opus",
     prompt: "<변경 요청 상세 + terraform/ 디렉토리 현재 상태 읽기 지시>"
   )
   ```
2. 에이전트가 .tf 파일과 apps.json을 직접 수정

**Phase 2: Plan 검증**
1. `drift-detector`에게 변경 검증 위임
   ```
   Agent(
     subagent_type: "drift-detector",
     model: "opus",
     prompt: "IaC 엔지니어가 다음 변경을 수행했다: <변경 요약>.
             terraform/ 디렉토리의 현재 파일을 읽고, 변경이 의도대로 되었는지 검증하라.
             terraform plan을 실행할 수 없으면 코드 리뷰 수준에서 검증하라.
             - apps.json과 dns.tf의 for_each 일관성
             - 기존 리소스에 대한 의도치 않은 영향
             - HCL 문법 정합성"
   )
   ```

**Phase 3: 결과 보고**
- 검증 통과 시: 변경 요약 + "terraform plan/apply는 CI에서 실행됩니다" 안내
- 검증 실패 시: 문제점 + 수정 제안. 최대 2회 재시도 (Phase 1 → 2 반복)

### B. 드리프트 점검 (독립 실행)

현재 인프라 상태 확인, 의도치 않은 변경 탐지 요청.

1. `drift-detector`에게 직접 위임
   ```
   Agent(
     subagent_type: "drift-detector",
     model: "opus",
     prompt: "<드리프트 점검 요청 + terraform/ 디렉토리 및 audit-orphans.yml 참조 지시>"
   )
   ```
2. 드리프트 분석 보고서 반환

### C. 상태 관리 (독립 실행)

state 건강 확인, import, state rm/mv, 잠금 해결 요청.

1. `state-manager`에게 직접 위임
   ```
   Agent(
     subagent_type: "state-manager",
     model: "opus",
     prompt: "<상태 관련 요청 + backend.tf 참조 지시>"
   )
   ```
2. 파괴적 작업(state rm, force-unlock)은 에이전트가 사용자 확인을 요청

### D. 복합 작업

여러 에이전트가 순차적으로 필요한 복합 요청 (예: "리소스 import 후 코드에 반영"):

1. `state-manager` → import 수행
2. `iac-engineer` → import된 리소스에 맞게 HCL 코드 작성
3. `drift-detector` → plan으로 no-diff 확인

## 기존 에이전트와의 경계

| 이 하네스 | 기존 에이전트 | 경계 |
|----------|-------------|------|
| `iac-engineer` | `provisioning-engineer` | IaC 엔지니어는 Terraform 코드만 담당. provisioning-engineer는 전체 앱 프로비저닝 체인(apps.json → K8s → ArgoCD)을 담당 |
| `drift-detector` | `audit-orphans.yml` | 드리프트 감지자는 온디맨드 심층 분석. 워크플로우는 주간 자동 감사 |
| `state-manager` | `pipeline-debugger` | 상태 관리자는 Terraform state 전문. pipeline-debugger는 GHA 전반 디버깅 |

## 데이터 흐름

```
[사용자 요청]
     │
     ├── HCL 변경 ─→ [iac-engineer] ─→ 파일 수정 ─→ [drift-detector] ─→ 검증 보고서
     │                                                      │
     │                                          실패 시 ←── 재시도 (최대 2회)
     │
     ├── 드리프트 점검 ─→ [drift-detector] ─→ 분석 보고서
     │
     ├── 상태 관리 ─→ [state-manager] ─→ 작업 결과
     │
     └── 복합 작업 ─→ [state-manager] → [iac-engineer] → [drift-detector]
```

## 에러 핸들링

| 상황 | 전략 |
|------|------|
| iac-engineer 코드 변경 실패 | 에러 분석 후 1회 재시도. 재실패 시 사용자에게 보고 |
| drift-detector 검증 실패 | 문제점을 iac-engineer에게 전달하여 수정 (최대 2회 루프) |
| state-manager 파괴적 작업 | 사용자 확인 없이 실행하지 않음 |
| Terraform CLI 접근 불가 | 코드 리뷰 수준에서 검증, plan 실행은 CI에서 안내 |
| R2 백엔드 인증 실패 | 인증 정보 확인 안내 (`-backend-config` 주입 필요) |

## 프로젝트 레퍼런스

Cloudflare Terraform provider 상세 정보가 필요하면:
- `.claude/skills/cloudflare/references/terraform/` 하위 파일을 읽는다 (configuration.md, gotchas.md, patterns.md)

## 테스트 시나리오

### 정상 흐름: 새 앱 DNS 추가
1. 사용자: "새 앱 grafana를 서브도메인 monitoring으로 DNS 추가해줘"
2. Phase 1: iac-engineer가 apps.json에 `"grafana": {"subdomain": "monitoring"}` 추가
3. Phase 2: drift-detector가 검증 — 새 CNAME 1개 추가, 기존 레코드 영향 없음
4. 결과: PASS, "terraform apply는 CI에서 실행됩니다" 안내

### 에러 흐름: 서브도메인 충돌
1. 사용자: "새 앱을 서브도메인 argo로 추가해줘"
2. Phase 1: iac-engineer가 apps.json 수정 시도
3. Phase 2: drift-detector가 검증 — argo 서브도메인이 argocd 앱과 충돌 감지
4. 결과: FAIL, "argo 서브도메인은 argocd가 사용 중" 보고, 대안 서브도메인 제안
