# GitOps 자동화 — 알려진 결함 및 문제

## 상태: Phase 4 테스트 진행 중 (2026-03-30)

---

## Critical — 현재 서비스 영향

### 1. Cloudflare Tunnel 502 에러 (photos + blog)

**증상**: `photos.ukkiee.dev`, `blog.ukkiee.dev` 모두 502 Bad Gateway

**원인 분석**:
- cloudflared pod는 Running, 4개 connection 등록됨 (Healthy)
- Cloudflare 대시보드에서 Public Hostname 정상 설정됨
- 클러스터 내부에서 traefik 경유 접근은 200 정상
- cloudflared 로그에 요청이 전혀 도달하지 않음 (0건)
- Cloudflare 엣지가 tunnel connector로 요청을 라우팅하지 않는 상태

**발생 시점**: terraform으로 `cloudflare_tunnel_config` → `cloudflare_zero_trust_tunnel_cloudflared_config` 리소스 마이그레이션 후

**시도한 해결**:
- cloudflared pod 재시작 (rollout restart) — 효과 없음
- cloudflared deployment 삭제 후 ArgoCD 자동 복구 — 효과 없음
- Cloudflare 대시보드에서 Public Hostname 삭제 후 재추가 — 효과 없음
- DNS 캐시 플러시 — 효과 없음

**추정 원인**: terraform `cloudflare_zero_trust_tunnel_cloudflared_config` 리소스가 tunnel 설정을 덮어쓰면서 Cloudflare 내부 라우팅 테이블이 꼬인 것으로 추정. 대시보드에서 수동으로 재설정해도 즉시 복구되지 않음.

**복구 방안 (미시도)**:
1. Cloudflare 대시보드에서 tunnel 삭제 후 재생성 (TUNNEL_TOKEN 변경 필요)
2. terraform state에서 tunnel config 리소스 제거 후 수동 관리로 복귀
3. Cloudflare 지원팀 문의

---

## High — 설계 결함

### 2. Template 레포 생성 시 첫 push의 race condition

**증상**: `gh repo create --template`으로 레포 생성 시, 초기 커밋이 자동으로 push되어 CI가 트리거됨. 사용자가 `.app-config.yml`을 수정하기 전에 setup이 실행되어 subdomain이 레포 이름(기본값)으로 설정됨.

**영향**:
- apps.json에 의도하지 않은 subdomain 등록
- IngressRoute와 DNS/Tunnel 설정 불일치
- 수동 teardown + 재설정 필요

**해결 방안**:
- A: template 레포에서 CI를 트리거하지 않도록 초기 커밋에 `[skip ci]` 포함
- B: 사용자가 template 내용을 로컬에 다운로드 → 설정 변경 → 레포 생성 & push (현재 workaround)
- C: setup job에서 이미 설정된 경우에도 config 변경 감지 시 재설정

### 3. GHCR 패키지 private 기본값 → imagePull 실패

**증상**: GHCR에 push된 패키지가 기본적으로 private → K3s에서 pull 시 denied

**근본 원인**:
- OrbStack K3s가 `/etc/rancher/k3s/registries.yaml`을 인식하지 않음 (표준 K3s와 다른 동작)
- GHCR 패키지 visibility를 API로 변경할 수 없음 (GitHub 무료 plan 제한)

**현재 workaround**:
- setup-app이 생성하는 deployment에 `imagePullSecrets: ghcr-secret` 포함
- 각 앱 네임스페이스에 수동으로 `ghcr-secret` 생성 필요

**문제점**: ghcr-secret 생성이 자동화되지 않음. 매번 수동:
```bash
kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=ukkiee-dev \
  --docker-password=<PAT> \
  -n <app-namespace>
```

**해결 방안**:
- A: GHCR 패키지를 수동으로 public 변경 (첫 빌드 후)
- B: setup-app action에서 kubectl로 ghcr-secret 자동 생성 (클러스터 접근 필요)
- C: SealedSecret으로 ghcr-secret을 manifests에 포함 (cluster-wide scope)

### 4. GitHub 무료 Org — Org Secrets private 레포 접근 제한

**증상**: Org Secrets의 "All repositories" 옵션이 실제로는 public 레포에서만 동작

**영향**: private 앱 레포에서 CI 실행 시 시크릿 접근 불가 → GitHub App 토큰 생성 실패

**현재 workaround**: homelab 레포를 public으로 전환, 앱 레포도 public으로 생성

**해결 방안**:
- A: 모든 레포를 public으로 유지 (현재 방식)
- B: GitHub Teams/Enterprise 플랜 업그레이드
- C: Org Secrets 대신 레포별 시크릿 사용 (자동화 필요)

---

## Medium — 운영 불편

### 5. cloudflared 재시작 시 tunnel 연결 불안정

**증상**: K3s 재시작 또는 cloudflared pod 재시작 후 tunnel 연결이 등록되지만 Cloudflare 엣지에서 요청이 라우팅되지 않는 경우 발생

**영향**: 502 에러, 수분~수십분 소요되어 복구되거나 복구 안 됨

**추정 원인**: Cloudflare 엣지의 tunnel connector 캐시 갱신 지연

### 6. Terraform과 Cloudflare 대시보드 간 설정 충돌

**증상**: terraform apply 후 대시보드에서 수동 변경하거나, 대시보드 변경 후 terraform apply하면 설정이 덮어씌워짐

**원인**: `cloudflare_zero_trust_tunnel_cloudflared_config`는 전체 config를 replace하므로 부분 업데이트 불가

**영향**: terraform과 대시보드 양쪽에서 관리하면 상태 불일치 발생

### 7. Teardown 후 네임스페이스 수동 삭제 필요

**증상**: teardown workflow가 manifests/ArgoCD Application/DNS/Tunnel을 삭제하지만, K8s 네임스페이스는 남아있음

**원인**: ArgoCD의 `CreateNamespace=true`로 생성된 NS는 prune 대상이 아님

**workaround**: `kubectl delete namespace <name> --ignore-not-found`

---

## Low — 개선 사항

### 8. arm64/amd64 multi-platform 빌드 시간

**증상**: GitHub Actions runner(amd64)에서 arm64 빌드 시 QEMU 에뮬레이션으로 빌드 시간 증가 (~1분)

**해결 방안**: 자체 arm64 runner 사용 (arc-runners가 이미 설정됨)

### 9. 이전 GHCR 패키지 잔존

**증상**: 레포 삭제 후 GHCR 패키지가 남아있어 동일 이름으로 재생성 시 403 Forbidden

**workaround**: `gh api orgs/ukkiee-dev/packages/container/<name> -X DELETE`

### 10. R2 backend `skip_requesting_account_id` 누락

**상태**: 수정 완료 (backend.tf에 추가)

**원인**: Cloudflare R2는 S3 호환이지만 AWS STS를 지원하지 않음

---

## 테스트 중 수정 완료된 사항

| # | 문제 | 수정 |
|---|---|---|
| 1 | homelab Actions 접근 제한 (private → public) | homelab public 전환 |
| 2 | GitHub App Org 설치 해제됨 | 재설치 |
| 3 | R2 backend `skip_requesting_account_id` | backend.tf에 추가 |
| 4 | Docker Buildx 미설정 (gha 캐시) | `setup-buildx-action@v3` 추가 |
| 5 | node:22-alpine uid 1000 충돌 | adduser 제거 |
| 6 | package-lock.json 누락 | 생성 + 커밋 |
| 7 | @types/node 누락 | 의존성 추가 |
| 8 | arm64 이미지 미빌드 | multi-platform 빌드 추가 |
| 9 | OrbStack registries.yaml 미지원 | imagePullSecrets로 전환 |
| 10 | Org Secrets visibility (public only) | homelab + 앱 레포 public |
| 11 | Template race condition (subdomain) | 레포 생성 방식 변경 (workaround) |
| 12 | GHCR 패키지 잔존 (403) | API로 삭제 |

---

## 다음 우선순위

1. **Critical #1 해결** — Cloudflare Tunnel 502 복구
2. **#3 자동화** — ghcr-secret 자동 생성
3. **#2 해결** — template race condition 방지
4. **문서 업데이트** — gitops-automation-plan.md에 테스트 결과 반영
