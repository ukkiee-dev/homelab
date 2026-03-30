# Tunnel Ingress API 마이그레이션 계획 v2 — 2차 리뷰

> 대상 문서: `docs/tunnel-api-migration-plan.md` (v2, 1차 리뷰 반영본)
> 리뷰 일자: 2026-03-31

---

## 1차 리뷰 반영 상태

P0/P1 항목 모두 반영됨. 환경변수 전달, GET 응답 검증, remove 멱등성, curl 타임아웃, setup 실패 시 중단 — 모두 올바르게 적용되었다. v2는 v1 대비 실질적으로 안전해졌다.

---

## Part A: 스크립트 깊은 검토

### A.1 PUT payload를 문자열 보간으로 조립하는 위험

**현재** (line 183):
```bash
-d "{\"config\": $FINAL_CONFIG}"
```

`FINAL_CONFIG`은 jq 출력이라 유효한 JSON이지만, 셸 문자열 보간으로 JSON을 조립하는 패턴은 원칙적으로 불안전하다. `FINAL_CONFIG`에 예상 밖의 문자(예: 셸 확장 가능한 `$`, backtick 등)가 포함되면 깨질 수 있다.

**수정**: jq로 payload 전체를 조립

```bash
PAYLOAD=$(jq -n --argjson config "$FINAL_CONFIG" '{config: $config}')

PUT_RESPONSE=$(curl -s -w '\n%{http_code}' $CURL_OPTS -X PUT "$API_URL" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")
```

### A.2 `sed '$d'`로 HTTP 코드 분리하는 방식의 취약성

**현재**:
```bash
HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -1)
BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
```

API가 빈 body를 반환하면(예: 204 또는 비정상 응답) `sed '$d'`가 HTTP 코드까지 지워서 `BODY`가 빈 문자열이 된다. 이후 `jq -e`가 실패하므로 실제 문제는 안 되지만, 더 안정적인 패턴이 있다.

**대안**: HTTP 코드를 별도 파일에 쓰는 방식

```bash
HTTP_CODE=$(curl -s -o /tmp/tunnel-response.json -w '%{http_code}' $CURL_OPTS \
  -H "Authorization: Bearer $CF_TOKEN" "$API_URL") || {
  echo "❌ API 연결 실패"; exit 1
}
BODY=$(cat /tmp/tunnel-response.json)
```

이 방식은 body와 HTTP 코드 파싱이 완전히 분리되어 엣지 케이스가 없다. 단, `/tmp` 파일 잔존에 주의 (GitHub Actions runner는 ephemeral이므로 실제 문제 안됨).

### A.3 catch-all 필터링 조건이 너무 좁음

**현재** (line 136):
```bash
RULES=$(echo "$CONFIG" | jq '[.ingress[] | select(.service != "http_status:404")]')
```

`http_status:404`만 catch-all로 인식하지만, Cloudflare tunnel에서 catch-all은 hostname이 없는 모든 rule을 의미한다. 만약 누군가 대시보드에서 catch-all을 `http_status:503`이나 다른 값으로 변경했다면 이 필터가 놓친다.

**수정**: hostname이 없는 rule을 catch-all로 취급

```bash
RULES=$(echo "$CONFIG" | jq '[.ingress[] | select(.hostname)]')
CATCHALL=$(echo "$CONFIG" | jq '.ingress[-1]')  # 항상 마지막이 catch-all
```

이렇게 하면 catch-all의 service 값이 무엇이든 보존된다.

### A.4 add 시 hostname 같고 service 다른 경우 미처리

**현재**: 동일 hostname이 있으면 무조건 스킵

```bash
if [ "$EXISTING" -gt 0 ]; then
  echo "⏭️  $HOSTNAME 이미 존재, 스킵"
  exit 0
fi
```

**시나리오**: `blog.ukkiee.dev → http://traefik:80`이 이미 있는데, service를 `http://traefik:8080`으로 변경하고 싶은 경우. 현재는 스킵되어 변경 불가.

**대안**: `update` 액션을 추가하거나, add에서 hostname 동일+service 다르면 교체하는 로직 추가

```bash
add)
  EXISTING_SERVICE=$(echo "$RULES" | jq -r --arg h "$HOSTNAME" \
    '.[] | select(.hostname == $h) | .service // empty')
  if [ "$EXISTING_SERVICE" = "$SERVICE" ]; then
    echo "⏭️  $HOSTNAME 이미 동일한 service로 존재, 스킵"
    exit 0
  elif [ -n "$EXISTING_SERVICE" ]; then
    echo "🔄 $HOSTNAME service 변경: $EXISTING_SERVICE → $SERVICE"
    RULES=$(echo "$RULES" | jq --arg h "$HOSTNAME" '[.[] | select(.hostname != $h)]')
  fi
  # 새 rule 추가
  NEW_RULE=$(jq -n --arg h "$HOSTNAME" --arg s "$SERVICE" '{hostname: $h, service: $s}')
  UPDATED=$(echo "$RULES" | jq --argjson rule "$NEW_RULE" '. + [$rule]')
  ;;
```

이 시나리오는 현재 모든 앱이 `http://traefik:80`을 쓰므로 당장은 발생하지 않지만, 방어적으로 처리해두면 좋다.

### A.5 ShellCheck 경고: 따옴표 없는 `$CURL_OPTS`

```bash
curl -s -w '\n%{http_code}' $CURL_OPTS ...
```

`$CURL_OPTS`가 따옴표 없이 사용된다. 의도적(word splitting으로 여러 옵션 전달)이지만 ShellCheck SC2086 경고가 나온다. 배열로 변경하면 깔끔하다:

```bash
CURL_OPTS=(--connect-timeout 10 --max-time 30)
curl -s "${CURL_OPTS[@]}" ...
```

---

## Part B: Workflow 통합 검토

### B.1 Concurrency 분석 — 교차 레포 동시 실행 Gap

문서의 concurrency 분석은 정확하지만 한 가지 Gap이 있다:

- `teardown.yml`은 homelab 레포에서 실행 → `homelab-terraform` group 적용 ✅
- `setup-app`은 **앱 레포의 CI workflow**에서 composite action으로 실행 → concurrency group은 **앱 레포의 workflow에서 정의**

만약 앱 레포의 CI workflow에도 `homelab-terraform` concurrency group이 있다면 괜찮지만, 이 group은 **레포 단위로 격리**된다. 즉:

```
test-blog 레포 CI (homelab-terraform group) → 독립
homelab 레포 teardown (homelab-terraform group) → 독립
```

이 두 개는 **동시에 실행 가능**하다. setup과 teardown이 같은 앱을 대상으로 동시에 돌면 문제.

**현실적 평가**: homelab 규모에서 같은 앱의 setup과 teardown이 동시에 트리거될 확률은 매우 낮다. 하지만 문서에 이 제약을 명시해야 한다.

**실제 위험 시나리오**:
```
1. test-blog CI 실행 → setup-app에서 tunnel add 시작
2. 동시에 teardown dispatch → tunnel remove 실행
3. GET→PUT race → 결과 비결정적
```

### B.2 setup-app에서 `inputs.subdomain.$inputs.domain`을 직접 셸 보간

**현재** (v2 plan line 216):
```yaml
run: |
  bash _homelab/.github/scripts/manage-tunnel-ingress.sh \
    add "${{ inputs.subdomain }}.${{ inputs.domain }}"
```

`${{ inputs.subdomain }}`은 workflow input에서 직접 셸에 삽입된다. GitHub Actions의 `${{ }}` 표현식은 셸 인젝션에 취약할 수 있다 (공격자가 subdomain에 `"; rm -rf /` 같은 값을 넣으면 실행됨).

이 경우 `inputs.subdomain`은 앱 레포의 `.app-config.yml`에서 오고, setup-app을 호출하는 것은 앱 레포의 CI이므로 공격자가 PR로 subdomain을 조작할 수 있다.

**수정**: 환경변수로 전달

```yaml
env:
  CF_TOKEN: ${{ inputs.tf-cloudflare-token }}
  ACCOUNT_ID: ${{ inputs.tf-account-id }}
  TUNNEL_ID: ${{ inputs.tf-tunnel-id }}
  HOSTNAME: "${{ inputs.subdomain }}.${{ inputs.domain }}"
run: |
  bash _homelab/.github/scripts/manage-tunnel-ingress.sh add "$HOSTNAME"
```

`env:`로 전달하면 GitHub Actions가 값을 환경변수로 설정하므로 셸 인젝션이 방지된다.

### B.3 Terraform apply 실패 시 tunnel API 스텝 실행 여부

setup-app action에서:
```
Step 2: Terraform apply (DNS CNAME)  → 실패하면?
Step 2.5: Tunnel API (add)           → 조건부 실행?
```

현재 계획에서 Step 2.5는 `if: ${{ inputs.type != 'worker' }}`만 확인한다. Terraform이 실패하면 composite action의 이후 step은 기본적으로 스킵되므로 tunnel API는 실행 안 된다 (정상).

하지만 **Terraform이 부분 실패**하는 경우(예: DNS CNAME은 이미 있어서 no-op, 다른 리소스가 실패):
- step 전체가 실패로 처리됨
- tunnel API가 스킵됨
- DNS는 있는데 tunnel ingress는 없는 상태

이 경우 재실행하면 Terraform은 성공하고 tunnel API도 성공하므로 복구 가능. 문제없다.

---

## Part C: 앱 레포 제거 시 분석

### C.1 현재 앱 라이프사이클 전체 흐름

```
생성: 앱 레포 push → CI → setup-app (DNS + Tunnel + K8s + ArgoCD + git push)
운영: 앱 레포 push → CI → _update-image.yml (이미지 태그 업데이트)
제거: teardown.yml (수동 dispatch) → DNS 삭제 + 매니페스트 삭제 + git push
```

### C.2 시나리오별 잔존 리소스 분석

#### 시나리오 1: 정상 경로 (teardown → 레포 삭제)

```
1. teardown dispatch (앱 이름 입력)
2. apps.json에서 제거
3. Terraform apply → DNS CNAME 삭제
4. [v2 추가] Tunnel API → ingress rule 제거
5. manifests/ + argocd/ 파일 삭제 → git push
6. ArgoCD 감지 → K8s 리소스 prune (Deployment, Service, IngressRoute)
7. 사용자가 앱 레포 삭제
```

**잔존 리소스**:

| 리소스 | 상태 | 자동 정리 | 수동 필요 |
|---|---|---|---|
| DNS CNAME | 삭제됨 ✅ | terraform | - |
| Tunnel Ingress | 삭제됨 ✅ | API script | - |
| K8s Deployment/Service | 삭제됨 ✅ | ArgoCD prune | - |
| K8s IngressRoute | 삭제됨 ✅ | ArgoCD prune | - |
| K8s Namespace | **잔존** ❌ | - | `kubectl delete ns` |
| GHCR Package | **잔존** ❌ | - | `gh api ... -X DELETE` |
| ArgoCD Application | 삭제됨 ✅ | git push | - |
| apps.json entry | 삭제됨 ✅ | teardown | - |
| homelab manifests | 삭제됨 ✅ | teardown | - |
| GitHub 레포 | 사용자 삭제 | - | - |

#### 시나리오 2: 위험 경로 (레포 먼저 삭제, teardown 나중)

사용자가 teardown 실행 없이 앱 레포를 먼저 삭제하는 경우.

**즉시 영향**:
```
레포 삭제 직후:
- 앱은 계속 정상 작동! (모든 인프라가 homelab 레포 + Cloudflare에 있음)
- CI/CD만 중단 (이미지 업데이트 불가)
- GHCR 패키지는 레포와 독립적으로 존재 (삭제 안 됨)
```

**이후 teardown 실행**:
- 정상 동작한다. teardown은 homelab 레포의 파일만 조작하므로 앱 레포 존재 여부와 무관.
- 유일한 차이: GHCR 패키지가 남아있어 동일 이름 재생성 시 403

**결론**: 레포 삭제 순서가 바뀌어도 teardown은 정상 작동. 하지만 teardown을 잊으면 시나리오 3으로.

#### 시나리오 3: 최악 경로 (레포 삭제, teardown 안 함)

**잔존 리소스 전체**:

| 리소스 | 상태 | 영향 |
|---|---|---|
| DNS CNAME | **잔존** | 트래픽이 계속 tunnel로 라우팅 |
| Tunnel Ingress | **잔존** | Cloudflare edge가 계속 요청 전달 |
| K8s Deployment | **잔존** | Pod 계속 실행, CPU/메모리 소모 |
| K8s Service | **잔존** | - |
| K8s IngressRoute | **잔존** | Traefik이 계속 라우팅 |
| K8s Namespace | **잔존** | - |
| ArgoCD Application | **잔존** | selfHeal로 수동 삭제도 복구함 |
| apps.json entry | **잔존** | 다음 terraform apply에 포함 |
| homelab manifests | **잔존** | ArgoCD sync 대상 |
| GHCR Package | **잔존** | 동일 이름 재생성 시 403 |

**실질적 문제**:
1. 앱이 영원히 실행됨 (리소스 낭비)
2. 오래된 이미지의 취약점이 패치 안 됨
3. 이후 같은 이름으로 재생성 시 충돌
4. DNS/tunnel에 불필요한 엔트리 쌓임

#### 시나리오 4: teardown 중 Tunnel API만 실패

```
1. apps.json 제거 ✅
2. Terraform apply (DNS 삭제) ✅
3. Tunnel API (remove) ❌ ← 실패 (continue-on-error: true)
4. manifests 삭제 ✅
5. git push ✅
```

**결과**:
- DNS CNAME 없음 → 사용자가 `blog.ukkiee.dev` 접속 시 DNS 해석 실패 (NXDOMAIN)
- Tunnel ingress rule 잔존 → **실질적 영향 없음** (DNS가 없으므로 도달 불가)
- 하지만 tunnel config에 쓸모없는 rule이 쌓임 → 시간이 지나면 가독성 저하

**대응**: 크리티컬하지 않지만, 정기적으로 `list` 액션으로 잔존 rule 확인 권장

#### 시나리오 5: teardown 중 Terraform만 실패

```
1. apps.json 제거 ✅
2. Terraform apply ❌ ← 실패 (workflow 중단)
3~5 실행 안 됨
```

**결과**:
- apps.json은 이미 수정됨 → git push 전이므로 **로컬 변경만** (원격에 반영 안 됨)
- 하지만 `git add terraform/apps.json`이 Commit & Push step에서 실행됨
- Terraform 실패 시 이후 step이 스킵되므로 → apps.json 변경도 push 안 됨 ✅
- 모든 리소스 그대로 잔존 → **재실행하면 됨**

### C.3 누락된 정리 항목: 앱 레포 삭제 시 자동화 Gap

현재 teardown이 처리하지 않는 것들:

| 항목 | 현재 | 자동화 가능 여부 |
|---|---|---|
| K8s Namespace 삭제 | 수동 | teardown에 kubectl step 추가 (클러스터 접근 필요) |
| GHCR Package 삭제 | 수동 | teardown에 `gh api` step 추가 가능 |
| Tunnel 잔존 rule 감사 | 없음 | 정기 cron workflow로 apps.json과 tunnel config 비교 |
| 레포 삭제 감지 | 없음 | Organization webhook + `repository.deleted` 이벤트 |

---

## Part D: 추가 발견사항

### D.1 setup-app action.yml의 오래된 주석

```yaml
# Tunnel ingress는 Cloudflare 대시보드에서 수동 추가 필요
```

v2 구현 후 이 주석을 업데이트해야 한다. 안 그러면 다음에 코드를 읽는 사람이 혼란스러워한다.

### D.2 setup-app action description도 업데이트 필요

```yaml
description: Terraform(DNS+Tunnel) → 매니페스트 생성 → git push 순서 보장
```

현재 description에 "Tunnel"이 있지만 실제로는 Terraform이 tunnel을 관리하지 않는다. v2 이후:

```yaml
description: Terraform(DNS) + Tunnel API → 매니페스트 생성 → git push 순서 보장
```

### D.3 gitops-known-issues.md #7과의 연계

Known issues #7: "Teardown 후 네임스페이스 수동 삭제 필요"

Tunnel API 마이그레이션과 직접 관련은 없지만, teardown workflow를 수정하는 김에 namespace 삭제 자동화도 같이 넣으면 효율적이다. ArgoCD Application에 `foregroundDeletion` finalizer를 추가하면 Application 삭제 시 namespace까지 정리 가능:

```yaml
metadata:
  finalizers:
    - resources-finalizer.argocd.argoproj.io/foreground
```

단, 이 finalizer를 추가하면 `prune: true`와 함께 동작 시 실수로 Application을 삭제하면 모든 리소스가 연쇄 삭제되므로 주의.

### D.4 GHCR 패키지 자동 정리 제안

teardown workflow에 GHCR 정리 step을 추가하면 수동 작업이 줄어든다:

```yaml
- name: Delete GHCR package
  continue-on-error: true
  env:
    GH_TOKEN: ${{ steps.app-token.outputs.token }}
    APP_NAME: ${{ inputs.app-name }}
  run: |
    gh api "orgs/ukkiee-dev/packages/container/${APP_NAME}" -X DELETE \
      && echo "✅ GHCR 패키지 삭제" \
      || echo "⏭️  GHCR 패키지 없음 또는 삭제 실패 (무시)"
```

단, GitHub App 토큰에 `packages:write` 권한이 필요하다. 현재 GitHub App은 `contents:write`만 있으므로 권한 추가 필요.

---

## Part E: 요약

### 스크립트 추가 수정사항

| 우선순위 | 항목 | 참조 |
|---|---|---|
| P1 | PUT payload를 jq로 조립 (문자열 보간 제거) | A.1 |
| P1 | workflow에서 hostname을 env로 전달 (셸 인젝션 방지) | B.2 |
| P2 | catch-all 필터를 hostname 유무 기반으로 변경 | A.3 |
| P2 | `$CURL_OPTS`를 배열로 변경 | A.5 |
| P3 | hostname 동일 + service 변경 케이스 처리 | A.4 |
| P3 | HTTP 코드 분리를 파일 기반으로 변경 | A.2 |

### 레포 제거 관련

| 우선순위 | 항목 | 참조 |
|---|---|---|
| P1 | 문서에 "teardown 먼저, 레포 삭제 나중" 순서 명시 | C.2 |
| P2 | teardown에 GHCR 패키지 삭제 step 추가 | D.4 |
| P2 | setup-app 주석/description 업데이트 | D.1, D.2 |
| P3 | Tunnel 잔존 rule 감사 방법 문서화 | C.3 |
| P3 | ArgoCD finalizer로 namespace 자동 삭제 검토 | D.3 |

### 시나리오별 위험도

| 시나리오 | 위험도 | 대응 |
|---|---|---|
| 정상 (teardown → 레포 삭제) | 낮음 | NS, GHCR만 수동 정리 |
| 레포 먼저 삭제 → teardown | 낮음 | teardown 정상 동작, GHCR 수동 정리 |
| 레포 삭제 + teardown 안 함 | **높음** | 모든 리소스 잔존, 수동 전체 정리 필요 |
| teardown 중 Tunnel API만 실패 | 낮음 | DNS 없으므로 실질적 영향 없음, rule만 잔존 |
| teardown 중 Terraform만 실패 | 낮음 | 재실행으로 복구 |
