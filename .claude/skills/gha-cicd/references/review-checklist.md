# GitHub Actions 리뷰 체크리스트

워크플로우를 보안·효율성·비용 3개 축으로 감사하는 체크리스트.

## 목차

1. [보안](#1-보안)
2. [효율성](#2-효율성)
3. [비용](#3-비용)
4. [일관성](#4-일관성)
5. [판정 기준](#5-판정-기준)

---

## 1. 보안

### Critical
- [ ] **시크릿 로그 노출**: `echo`, `run` 블록에서 시크릿 값이 stdout에 출력되지 않는지
- [ ] **시크릿 CLI 인자**: 시크릿이 환경변수가 아닌 CLI 인자로 전달되지 않는지 (ps/proc 노출)
- [ ] **시크릿 스텝 출력**: `set-output`이나 `$GITHUB_OUTPUT`으로 시크릿이 노출되지 않는지
- [ ] **서드파티 액션 고정**: SHA 또는 major version 태그(`@v1`, `@v4`)로 고정되었는지
- [ ] **과도한 permissions**: `GITHUB_TOKEN` 권한이 최소 원칙을 따르는지
- [ ] **command injection**: `${{ inputs.* }}`나 `${{ github.event.* }}`가 셸에 직접 보간되지 않는지 (환경변수 경유 필수)

### Warning
- [ ] **fork PR 보안**: `pull_request_target`에서 fork의 코드를 체크아웃+실행하지 않는지
- [ ] **artifact 오염**: 업로드된 artifact를 신뢰 없이 다운로드+실행하지 않는지
- [ ] **OIDC 미사용**: 장기 시크릿 대신 OIDC 연동 가능한 서비스(AWS, GCP)가 있는지

### Info
- [ ] **시크릿 네이밍**: 프로젝트 시크릿 레지스트리(workflow-patterns.md)와 일치하는지
- [ ] **토큰 스코프 문서화**: 어떤 권한이 왜 필요한지 주석이 있는지

---

## 2. 효율성

### Warning
- [ ] **불필요한 체크아웃**: 소스 코드가 필요 없는 잡에서 `actions/checkout` 실행
- [ ] **중복 설치**: 같은 도구(yq, terraform)를 여러 잡에서 반복 설치
- [ ] **캐싱 미활용**: npm/pip/terraform provider 등 캐싱 가능한 의존성이 매번 다운로드
- [ ] **순차 실행 가능한 병렬화**: 독립적인 잡이 `needs`로 불필요하게 직렬화
- [ ] **과도한 git clone**: `fetch-depth: 0`이 불필요한 경우 (태그/히스토리 불필요)

### Info
- [ ] **조건부 실행**: 변경되지 않은 파일에 대해 불필요한 스텝이 실행되는지
- [ ] **매트릭스 활용**: 반복적인 잡이 매트릭스로 통합 가능한지

---

## 3. 비용

### Warning
- [ ] **러너 선택**: kubectl이 필요한 경우만 self-hosted, 나머지는 `ubuntu-latest`
- [ ] **Terraform init 반복**: 같은 잡 내 여러 스텝에서 불필요하게 init 반복
- [ ] **불필요한 빌드**: 변경이 없는데 워크플로우가 트리거되는 경로 필터 누락

### Info
- [ ] **타임아웃 설정**: `timeout-minutes`가 설정되었는지 (기본 6시간은 과도)
- [ ] **ARC 스케일링 영향**: self-hosted runner 사용 시 idle 러너가 스케일다운 가능한지

---

## 4. 일관성

### Warning
- [ ] **Push Retry 패턴**: git push가 있으면 3회 재시도 루프 적용 여부
- [ ] **Concurrency 그룹**: 인프라 변경 워크플로우에 concurrency 설정 여부
- [ ] **알림 패턴**: success/failure 알림이 Telegram으로 전송되는지
- [ ] **Git 설정**: `deploy-bot` 사용자명/이메일 일관성
- [ ] **입력 검증**: `workflow_dispatch` 입력에 검증 스텝 존재 여부

### Info
- [ ] **네이밍**: 재사용 워크플로우는 `_` 접두사, 스크립트는 `.github/scripts/`
- [ ] **주석**: 한국어 주석 일관성
- [ ] **yq 사용법**: `strenv()` 패턴 사용 여부 (직접 보간 대신)

---

## 5. 판정 기준

| 판정 | 조건 |
|------|------|
| **PASS** | Critical 0개, Warning 2개 이하 |
| **WARN** | Critical 0개, Warning 3개 이상 |
| **FAIL** | Critical 1개 이상 |

리포트 형식:
```
## 보안
- [CRITICAL] 시크릿 X가 echo로 출력됨 (line 45) — echo 제거하고 마스킹 확인
- [WARNING] 서드파티 액션 Y가 @latest로 고정 — SHA 또는 @v2로 고정

## 효율성
- [WARNING] job A와 B가 독립적인데 needs로 직렬화 — needs 제거로 병렬 실행

## 비용
- [INFO] timeout-minutes 미설정 — 30분으로 설정 권장

## 요약
Critical: 1, Warning: 2, Info: 1
전체 판정: FAIL
```
