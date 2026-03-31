# 드리프트 분석 레퍼런스

드리프트 감지자가 terraform plan 출력을 분석할 때 참조하는 가이드.

## 목차

1. [Plan 출력 해석](#plan-출력-해석)
2. [드리프트 유형별 대응](#드리프트-유형별-대응)
3. [Cloudflare DNS 특수 사항](#cloudflare-dns-특수-사항)
4. [기존 감사 자동화와 연계](#기존-감사-자동화와-연계)
5. [코드 리뷰 수준 검증](#코드-리뷰-수준-검증)

---

## Plan 출력 해석

### 변경 기호

| 기호 | 의미 | 주의도 |
|------|------|--------|
| `+` | 리소스 생성 | 의도된 추가인지 확인 |
| `-` | 리소스 삭제 | 항상 주의. 의도된 삭제인지 반드시 확인 |
| `~` | 리소스 수정 (in-place) | 어떤 attribute가 변경되는지 확인 |
| `-/+` | 리소스 재생성 (destroy + create) | 높은 주의. DNS 다운타임 발생 가능 |

### 변경 요약 패턴

```
Plan: N to add, N to change, N to destroy.
```

이 줄이 예상과 다르면 상세 분석 필요.

## 드리프트 유형별 대응

### 1. 의도된 변경 (INFO)

apps.json 수정에 따른 예상 변경. add/destroy 수가 apps.json 변경 수와 일치하면 정상.

**확인 방법:**
- apps.json의 변경된 키 수 = plan의 add/destroy 수
- 변경되지 않은 리소스에 영향 없음

### 2. 외부 드리프트 (WARNING)

Cloudflare 콘솔이나 API에서 직접 수정된 레코드. plan에서 `~` (in-place update)로 나타남.

**흔한 원인:**
- Cloudflare 대시보드에서 수동 DNS 수정
- Tunnel ingress 스크립트(manage-tunnel-ingress.sh)와 Terraform 간 불일치
- Cloudflare 자동 설정 변경 (예: proxy 상태)

**대응:**
- `terraform plan`으로 차이 확인
- 실제 상태가 올바르면 `terraform apply`로 state 동기화
- Terraform 코드가 올바르면 `terraform apply`로 인프라 동기화

### 3. 상태 불일치 (WARNING)

state에 리소스가 있지만 실제 인프라에 없거나, 그 반대.

**흔한 원인:**
- Cloudflare 콘솔에서 레코드 삭제 (state는 모름)
- `terraform import` 없이 수동 생성된 레코드
- state 파일 손상/복구

**대응:**
- 실제 존재하는데 state에 없음 → `terraform import`
- state에 있는데 실제 없음 → `terraform state rm` 또는 `terraform apply`로 재생성

### 4. 예상외 재생성 (CRITICAL)

`-/+` (force replacement). DNS 레코드가 삭제 후 재생성되면 전파 지연으로 다운타임 발생.

**흔한 원인:**
- `for_each` key 변경 (앱 이름 변경)
- 리소스의 force-new attribute 변경
- Provider 업그레이드로 인한 리소스 스키마 변경

**대응:**
- `terraform state mv`로 주소 변경 (destroy 방지)
- key 변경이 불가피하면 다운타임 영향 평가 후 진행

## Cloudflare DNS 특수 사항

### Proxied CNAME

모든 앱 CNAME은 `proxied = true`다. 이는 Cloudflare의 DNS proxy를 통과함을 의미:
- 실제 CNAME 대상(`{tunnel_id}.cfargotunnel.com`)이 클라이언트에 노출되지 않음
- Cloudflare가 A 레코드(anycast IP)로 응답
- proxy 상태 변경은 트래픽 라우팅에 즉시 영향

### Tunnel CNAME 대상

모든 레코드의 content가 `{tunnel_id}.cfargotunnel.com`으로 동일. tunnel_id 변경 시 모든 레코드가 변경됨에 주의.

## 기존 감사 자동화와 연계

### audit-orphans.yml

주간 월요일 00:00 UTC 자동 실행. 두 가지 드리프트를 감지:

1. **Orphan apps**: apps.json에 있지만 GitHub repo가 없는 앱
2. **Tunnel drift**: apps.json 기반 DNS 레코드와 실제 Tunnel ingress 규칙 불일치

이 워크플로우는 "존재 여부" 수준의 감사다. 드리프트 감지자는 더 깊은 수준(attribute 변경, state 불일치)의 분석을 수행한다.

## 코드 리뷰 수준 검증

`terraform plan`을 실행할 수 없는 환경(로컬 인증 없음)에서의 검증 절차:

1. **apps.json 정합성**: JSON 문법, 중복 키/서브도메인, 기존 항목 호환
2. **HCL 문법**: 리소스 블록 구조, 변수 참조, interpolation 문법
3. **for_each 일관성**: apps.json 키와 리소스 주소 패턴 일치
4. **변수 참조**: 사용된 변수가 variables.tf에 정의되어 있는지
5. **Provider 호환성**: 사용된 리소스/attribute가 provider 버전 제약 내인지
6. **부수효과 예측**: 변경이 기존 리소스의 destroy/recreate를 유발하지 않는지
