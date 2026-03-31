# GitHub Actions 디버그 플레이북

워크플로우 실패 시 체계적으로 근본 원인을 추적하는 절차.

## 목차

1. [진단 워크플로우](#1-진단-워크플로우)
2. [에러 유형별 플레이북](#2-에러-유형별-플레이북)
3. [gh CLI 진단 명령](#3-gh-cli-진단-명령)
4. [프로젝트 고유 실패 패턴](#4-프로젝트-고유-실패-패턴)

---

## 1. 진단 워크플로우

```
1. 증상 수집
   └→ gh run view <id> --log-failed
   └→ gh run view <id> --json jobs,conclusion,startedAt,updatedAt

2. 에러 분류
   ├→ 권한: "permission denied", "403", "401", "token"
   ├→ 환경: "command not found", "state lock", "timeout"
   ├→ 로직: "exit 1", assertion 실패, 조건문 오류
   ├→ 인프라: "runner not found", "no space", OOM
   └→ 외부API: "rate limit", "500", "connection refused"

3. 근본 원인 추적
   └→ 해당 유형의 플레이북 실행

4. 수정 + 재발 방지
   └→ 구체적 변경사항 + 장기 대책
```

---

## 2. 에러 유형별 플레이북

### 권한 문제

**증상**: `403 Forbidden`, `Resource not accessible by integration`, `permission denied`

**체크 순서**:
1. GitHub App Token이 올바른 레포에 대해 생성되었는지 확인
   - `repositories: homelab` 설정 확인
   - App 설정에서 필요한 권한(contents: write, packages: write) 확인
2. `GITHUB_TOKEN` 권한 부족 — `permissions:` 블록 추가
3. 시크릿이 올바른 environment에 설정되었는지 (repo vs env 시크릿)
4. Fork PR에서 실행 시 시크릿 접근 불가 (보안 정책)

### 환경 문제

**증상**: `command not found`, `terraform: state lock`, `connection timed out`

**체크 순서**:
1. 도구 설치 스텝 누락 또는 순서 오류 (yq, terraform, gh)
2. Terraform state lock — 다른 실행이 lock을 잡고 있는지 확인
   - `terraform force-unlock <LOCK_ID>` (주의: 다른 실행이 진행 중이면 위험)
3. API 타임아웃 — Cloudflare API 상태 확인, retry 로직 추가
4. `working-directory` 설정 오류 — 경로 확인

### 로직 오류

**증상**: `exit 1` (커스텀 검증 실패), 예상과 다른 분기 실행

**체크 순서**:
1. 셸 변수가 비어있는지 (`set -euo pipefail`에서 unset 변수 감지)
2. `if` 조건의 `${{ }}` 표현식 평가 결과 확인
3. `jq` 쿼리가 올바른 JSON 구조를 기대하는지
4. `steps.*.outcome` 참조가 올바른 step ID를 가리키는지

### 인프라 문제

**증상**: `Could not find a runner`, `disk space`, `OOM killed`

**체크 순서**:
1. ARC 러너 상태 확인 — 스케일업 지연 가능 (0에서 올라오는 데 1-2분)
2. 러너 라벨 확인 — `runs-on` 값이 ARC 설정과 일치하는지
3. 러너 리소스 부족 — Pod 리소스 제한 확인
4. 노드 리소스 부족 — K3s 노드의 CPU/메모리 여유 확인

### 외부 API 문제

**증상**: `429 Too Many Requests`, `500 Internal Server Error`, `connection refused`

**체크 순서**:
1. Cloudflare API rate limit — 1200 req/5min
2. GitHub API rate limit — `gh api rate_limit`로 확인
3. Cloudflare/GitHub 서비스 장애 — status 페이지 확인
4. retry 로직이 있는지 (없으면 추가 권장)

---

## 3. gh CLI 진단 명령

```bash
# 최근 실행 목록
gh run list --limit 10

# 특정 실행의 실패 로그
gh run view <run-id> --log-failed

# 실행 상태 JSON
gh run view <run-id> --json jobs,conclusion,startedAt,updatedAt

# 특정 잡의 로그
gh run view <run-id> --log --job <job-id>

# 러너 상태
gh api repos/{owner}/{repo}/actions/runners

# API rate limit 확인
gh api rate_limit

# 수동으로 워크플로우 트리거
gh workflow run <workflow-file> -f param1=value1

# 최근 5회 실행의 결론 (간헐적 실패 패턴 분석)
gh run list --workflow <workflow-file> --limit 5 --json conclusion,createdAt
```

---

## 4. 프로젝트 고유 실패 패턴

| 증상 | 빈도 | 근본 원인 | 해결 |
|------|------|----------|------|
| push 실패 3회 반복 | 드묾 | 동시 워크플로우가 같은 파일 수정 | concurrency group 통합 또는 직렬화 |
| Terraform plan 실패 | 가끔 | R2 백엔드 접근 실패 (토큰 만료) | R2 시크릿 갱신 |
| Tunnel API 실패 | 드묾 | CF_TOKEN 권한 부족 | API token에 Tunnel 편집 권한 추가 |
| yq 설치 실패 | 매우 드묾 | GitHub 서비스 장애 | 재실행으로 해결 |
| apps.json 파싱 오류 | 드묾 | 유효하지 않은 JSON (수동 편집 오류) | `jq empty` 검증 스텝 추가 |
| ArgoCD Application 삭제 실패 | 가끔 | kubectl 미설치 (ubuntu-latest) | self-hosted runner에서만 실행 |
| GHCR 패키지 삭제 실패 | 가끔 | 패키지 없음 또는 권한 부족 | `continue-on-error: true` (의도된 동작) |

### 간헐적 실패 (Flaky) 대응

간헐적 실패가 의심되면:
1. `gh run list --workflow <file> --limit 10 --json conclusion,createdAt`로 패턴 확인
2. 동일 입력으로 성공/실패가 반복되면 환경 요인 (API rate limit, 러너 상태)
3. 특정 입력에서만 실패하면 로직 오류 (엣지케이스)
4. 특정 시간대에만 실패하면 외부 의존성 (스케줄, maintenance window)
