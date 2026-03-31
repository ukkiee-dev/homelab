# Homelab GitHub Actions 워크플로우 패턴

이 프로젝트의 워크플로우에서 반복적으로 사용하는 패턴을 정리한다. 새 워크플로우 작성 시 이 패턴을 따라 일관성을 유지하라.

## 목차

1. [GitHub App Token 생성](#1-github-app-token-생성)
2. [Push Retry 루프](#2-push-retry-루프)
3. [Concurrency 그룹](#3-concurrency-그룹)
4. [Terraform 백엔드 초기화](#4-terraform-백엔드-초기화)
5. [Cloudflare Tunnel 관리](#5-cloudflare-tunnel-관리)
6. [Telegram 알림](#6-telegram-알림)
7. [입력값 검증 패턴](#7-입력값-검증-패턴)
8. [YAML 조작 (yq)](#8-yaml-조작-yq)
9. [시크릿 레지스트리](#9-시크릿-레지스트리)
10. [워크플로우 네이밍](#10-워크플로우-네이밍)

---

## 1. GitHub App Token 생성

모든 cross-repo 접근에 GitHub App Token을 사용한다. PAT 대신 App Token을 쓰는 이유: 권한 범위를 레포 단위로 제한할 수 있고, 만료 관리가 자동이다.

```yaml
- name: Generate token
  id: app-token
  uses: actions/create-github-app-token@v1
  with:
    app-id: ${{ secrets.HOMELAB_APP_ID }}
    private-key: ${{ secrets.HOMELAB_APP_PRIVATE_KEY }}
    owner: ukkiee-dev
    repositories: homelab
```

사용: `${{ steps.app-token.outputs.token }}`

주의: `APP_ID` vs `HOMELAB_APP_ID` — 워크플로우마다 시크릿 이름이 다를 수 있다. `_update-image.yml`은 호출측에서 시크릿을 전달받으므로 `APP_ID`를 사용하고, 나머지는 `HOMELAB_APP_ID`를 사용한다.

---

## 2. Push Retry 루프

동시 push 경합을 해결하는 3회 재시도 패턴. 모든 git push 워크플로우에 적용한다.

```bash
PUSHED=false
for i in 1 2 3; do
  git rebase --abort 2>/dev/null || true
  git pull --rebase origin main && git push && PUSHED=true && break || {
    echo "push 실패 ($i/3), 재시도..."
    sleep $((i * 5))
  }
done

if [ "$PUSHED" != "true" ]; then
  echo "3회 retry 후에도 push 실패"
  exit 1
fi
```

핵심:
- `rebase --abort`로 이전 실패한 rebase를 정리
- exponential backoff: 5초, 10초, 15초
- 3회 실패 시 exit 1

---

## 3. Concurrency 그룹

동시 실행 충돌을 방지한다. 작업 유형별로 그룹을 나눈다:

| 그룹 | 용도 | cancel-in-progress |
|------|------|-------------------|
| `homelab-manifest-update` | 매니페스트 수정 워크플로우 | false |
| `homelab-terraform` | Terraform 실행 워크플로우 | false |

```yaml
concurrency:
  group: homelab-manifest-update
  cancel-in-progress: false  # 항상 false — 인프라 변경은 취소하면 안 됨
```

`cancel-in-progress: false`인 이유: Terraform apply, git push 중간에 취소하면 상태 불일치가 발생한다.

---

## 4. Terraform 백엔드 초기화

Terraform state는 Cloudflare R2에 저장한다.

```yaml
- name: Terraform Init
  run: |
    terraform init \
      -backend-config="endpoint=https://${TF_ACCOUNT_ID}.r2.cloudflarestorage.com" \
      -backend-config="access_key=${R2_ACCESS_KEY}" \
      -backend-config="secret_key=${R2_SECRET_KEY}"
  working-directory: terraform
  env:
    TF_ACCOUNT_ID: ${{ secrets.TF_ACCOUNT_ID }}
    R2_ACCESS_KEY: ${{ secrets.R2_ACCESS_KEY_ID }}
    R2_SECRET_KEY: ${{ secrets.R2_SECRET_ACCESS_KEY }}
```

Plan/Apply에 필요한 환경변수:
```yaml
env:
  TF_VAR_cloudflare_api_token: ${{ secrets.TF_CLOUDFLARE_TOKEN }}
  TF_VAR_zone_id:              ${{ secrets.TF_ZONE_ID }}
  TF_VAR_tunnel_id:            ${{ secrets.TF_TUNNEL_ID }}
  TF_VAR_account_id:           ${{ secrets.TF_ACCOUNT_ID }}
  TF_VAR_domain:               ${{ secrets.TF_DOMAIN }}
```

---

## 5. Cloudflare Tunnel 관리

`.github/scripts/manage-tunnel-ingress.sh` 스크립트로 Tunnel ingress를 관리한다.

```yaml
- name: Add tunnel ingress
  continue-on-error: true  # 실패해도 apps.json 변경은 push해야 함
  env:
    CF_TOKEN: ${{ secrets.TF_CLOUDFLARE_TOKEN }}
    ACCOUNT_ID: ${{ secrets.TF_ACCOUNT_ID }}
    TUNNEL_ID: ${{ secrets.TF_TUNNEL_ID }}
    TUNNEL_HOSTNAME: "${{ inputs.subdomain }}.${{ secrets.TF_DOMAIN }}"
  run: |
    bash .github/scripts/manage-tunnel-ingress.sh add "$TUNNEL_HOSTNAME"
```

스크립트 명령: `add <hostname>`, `remove <hostname>`, `list`
드라이런: `DRY_RUN=true` 환경변수

주의: 시크릿은 반드시 환경변수로 전달 — CLI 인자로 토큰을 넘기면 ps/proc에 노출된다.

---

## 6. Telegram 알림

성공/실패 시 Telegram으로 알림을 보낸다.

```yaml
- name: Notify success (Telegram)
  if: success()
  env:
    TG_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
    TG_CHAT: ${{ secrets.TELEGRAM_CHAT_ID }}
  run: |
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      -d chat_id="${TG_CHAT}" \
      -d text="메시지 내용"

- name: Notify failure (Telegram)
  if: failure()
  env:
    RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
  run: |
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      -d chat_id="${TG_CHAT}" \
      -d text="실패 메시지%0A${RUN_URL}"
```

개행: `%0A` 사용 (URL 인코딩)

---

## 7. 입력값 검증 패턴

`workflow_dispatch` 입력은 반드시 검증한다:

```bash
# K8s namespace 호환 검증 (RFC 1123 DNS label)
if [[ ! "$APP" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]] || [ ${#APP} -gt 63 ]; then
  echo "::error::app-name은 소문자·숫자·하이픈만 허용"
  exit 1
fi

# 경로 형식 검증
if [ -n "$HEALTH" ] && [[ ! "$HEALTH" =~ ^/ ]]; then
  echo "::error::health 경로는 /로 시작해야 합니다"
  exit 1
fi

# 디렉토리 존재 확인
if [ ! -d "manifests/apps/$APP" ]; then
  echo "::error::manifests/apps/$APP 디렉토리가 없습니다"
  exit 1
fi
```

`::error::` 접두사로 GitHub Actions 어노테이션을 생성한다.

---

## 8. YAML 조작 (yq)

yq v4로 YAML을 안전하게 수정한다.

```yaml
- name: Install yq
  uses: mikefarah/yq@v4

- name: Update field
  env:
    VALUE: ${{ inputs.some-value }}
  run: |
    VALUE="$VALUE" yq -i '.some.path = strenv(VALUE)' file.yaml
```

핵심: `strenv()`로 환경변수를 문자열로 안전하게 주입. 직접 셸 보간(`$VALUE`)은 YAML 주입 위험이 있다.

YAML 정규화: heredoc으로 생성한 YAML은 들여쓰기가 깨질 수 있으므로 `yq eval -i '.' file.yaml`로 정규화한다.

---

## 9. 시크릿 레지스트리

이 프로젝트에서 사용하는 GitHub Actions 시크릿 목록:

| 시크릿 | 용도 |
|--------|------|
| `HOMELAB_APP_ID` | GitHub App ID |
| `HOMELAB_APP_PRIVATE_KEY` | GitHub App Private Key |
| `TF_CLOUDFLARE_TOKEN` | Cloudflare API Token |
| `TF_ZONE_ID` | Cloudflare Zone ID |
| `TF_TUNNEL_ID` | Cloudflare Tunnel ID |
| `TF_ACCOUNT_ID` | Cloudflare Account ID |
| `TF_DOMAIN` | 도메인 (ukkiee.dev) |
| `R2_ACCESS_KEY_ID` | R2 Storage Access Key |
| `R2_SECRET_ACCESS_KEY` | R2 Storage Secret Key |
| `TELEGRAM_BOT_TOKEN` | Telegram Bot Token |
| `TELEGRAM_CHAT_ID` | Telegram Chat ID |

`_update-image.yml`은 `workflow_call`이므로 호출측에서 `APP_ID`, `APP_PRIVATE_KEY`로 전달받는다.

---

## 10. 워크플로우 네이밍

| 컨벤션 | 예시 |
|--------|------|
| 재사용 워크플로우 | `_` 접두사: `_update-image.yml` |
| 일반 워크플로우 | 동작 설명: `teardown.yml`, `audit-orphans.yml` |
| 복합 액션 | `.github/actions/{name}/action.yml` |
| 셸 스크립트 | `.github/scripts/{name}.sh` |

커밋 메시지: `feat:` (새 워크플로우), `fix:` (워크플로우 수정), `chore:` (자동화 실행 결과)
