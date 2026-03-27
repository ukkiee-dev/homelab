# Homelab 종합 감사 보고서

> 분석일: 2026-03-27 | 클러스터: OrbStack K3s on Mac Mini M4
> 노드 리소스: CPU 810m (8%), Memory 5,672Mi (70%)

---

## 목차

1. [긴급 문제 (즉시 수정 필요)](#1-긴급-문제-즉시-수정-필요)
2. [보안 취약점](#2-보안-취약점)
3. [안정성 개선점](#3-안정성-개선점)
4. [리소스 & 성능 최적화](#4-리소스--성능-최적화)
5. [백업 & 재해복구 점검](#5-백업--재해복구-점검)
6. [CI/CD & GitOps 개선](#6-cicd--gitops-개선)
7. [추가 추천 서비스](#7-추가-추천-서비스)
8. [우선순위 로드맵](#8-우선순위-로드맵)

---

## 1. 긴급 문제 (즉시 수정 필요)

### 1-1. Traefik ArgoCD Sync 실패 (OutOfSync)

**현상:** ArgoCD에서 Traefik 앱이 OutOfSync 상태. sync 시도 시 아래 에러 발생:

```
Deployment.apps "traefik" is invalid:
spec.template.spec.containers[0].env[4].valueFrom:
Invalid value: "": may not be specified when `value` is not empty
```

**원인:** Traefik Helm 차트 v34.x에서 CPU/Memory limits 설정 시 `GOMAXPROCS`, `GOMEMLIMIT` 환경변수를 `resourceFieldRef`로 자동 생성한다. 사용자가 `values.yaml`에 추가한 `CF_DNS_API_TOKEN` (env[4]) 환경변수의 `valueFrom`과 Helm 템플릿의 내부 로직이 충돌하여, 하나의 env에 `value`와 `valueFrom`이 동시에 설정되는 문제가 발생.

**해결:**
- `values.yaml`의 `env` 블록 대신 Traefik 차트가 제공하는 `envFrom` 또는 `additionalEnvVars` 필드를 사용
- 또는 `env` 정의를 `extraEnvVars` 등 차트 버전에 맞는 키로 변경
- ArgoCD multi-source 구성에서 Helm + Kustomize 조합이 env를 이중 처리할 가능성 확인 필요

**영향도:** Traefik 설정 변경을 ArgoCD로 배포 불가. 현재 실행 중인 Traefik은 정상 동작하나, 다음 설정 변경 시 문제.

---

### 1-2. ArgoCD Image Updater 반복 재시작 (11회)

**현상:** `argocd-image-updater-controller` 파드가 11회 재시작됨.

```
argocd-image-updater-controller-8449c6ff5c-sh8p5  restarts=11
```

**원인:** 로그 확인 결과 `apps` namespace에서 Application을 찾지 못하는 반복 루프 발생. Image Updater가 `argocd` namespace와 `apps` namespace 양쪽을 스캔하도록 구성되어 있으나, ArgoCD Application은 `argocd` namespace에만 존재.

**해결:**
- Image Updater의 `targetNamespace` 또는 `applicationNamespaces` 설정을 `argocd`로 한정
- 불필요한 namespace 스캔 제거

---

### 1-3. CrowdSec LAPI Key 평문 노출

**파일:** `k8s/base/traefik/middlewares.yaml:101`

```yaml
crowdsecLapiKey: 45quR62Xp91t3XHh+O/Oq8XaIorc7QwOcT5gNNd7FxI
```

**위험:** API 키가 Git 저장소에 평문으로 커밋됨. 저장소 접근 권한이 있는 누구나 CrowdSec LAPI에 인증 가능.

**해결:**
- 즉시 CrowdSec LAPI 키를 회전 (현재 키는 이미 노출된 것으로 간주)
- Infisical 또는 SealedSecret으로 관리하고, Traefik Plugin 설정에서 환경변수로 참조
- `.gitignore`에 민감 정보 패턴 추가 검토

---

### 1-4. Homepage 파드 2개 동시 실행

**현상:** Homepage Rollout이 replica 1인데 파드가 2개 Running:

```
apps  homepage-668bcc7764-54x4b  Running  17h
apps  homepage-755745c5dd-cqkgw  Running  50m
```

**원인:** Blue-Green 전략에서 이전 ReplicaSet이 scaleDown되지 않음. `scaleDownDelayRevisionLimit`이 설정되었음에도 구 RS가 남아있을 수 있음.

**해결:** Argo Rollouts 컨트롤러가 방금 재시작(5m)되었으므로, 재시작 후 정리가 진행 중인지 확인. 지속되면 수동 `kubectl argo rollouts promote homepage -n apps` 실행.

---

## 2. 보안 취약점

### 2-1. NetworkPolicy 미적용 네임스페이스 (4개)

| 네임스페이스 | 워크로드 | 위험도 | 비고 |
|-------------|----------|--------|------|
| `argocd` | ArgoCD Server, Controller, Repo Server, Redis | **높음** | 클러스터 전체 접근 권한 보유 |
| `actions-runner-system` | ARC Controller, Runners | **높음** | 외부 코드 실행 가능 |
| `infisical` | Infisical, Operator, Redis | **높음** | 전체 시크릿 저장소 |
| `tailscale-system` | Tailscale Operator | 중간 | VPN 네트워크 관리 |

**권장:** 각 네임스페이스에 default-deny-all + 필요한 트래픽만 허용하는 정책 추가.

**특히 `argocd` 네임스페이스:**
```yaml
# 최소 허용 정책 예시
- Traefik → ArgoCD Server (ingress, port 8080)
- ArgoCD Controller → Kubernetes API (egress)
- ArgoCD Repo Server → Git repos (egress, port 443)
- ArgoCD → Redis (internal)
```

---

### 2-2. securityContext 미설정 워크로드 (5개)

| 워크로드 | 파일 | 누락 항목 |
|----------|------|----------|
| api-server | `k8s/base/api-server/rollout.yaml` | runAsNonRoot, readOnlyRootFilesystem, capabilities drop |
| immich-server | `k8s/base/immich/server.yaml` | 전체 securityContext |
| immich-ml | `k8s/base/immich/ml.yaml` | 전체 securityContext |
| immich-postgres | `k8s/base/immich/postgres.yaml` | 전체 securityContext |
| immich-redis | `k8s/base/immich/redis.yaml` | 전체 securityContext |

**잘 설정된 예시** (참고용):
- `cloudflared/deployment.yaml` - runAsNonRoot, readOnlyRootFilesystem, capabilities drop ALL
- `homepage/rollout.yaml` - runAsUser 1000, fsGroup 1000, readOnlyRootFilesystem
- `traefik/values.yaml` - runAsUser 65532, capabilities drop ALL + add NET_BIND_SERVICE

**권장:** 최소한 아래 설정을 모든 워크로드에 추가:
```yaml
securityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: true  # 쓰기 필요 시 emptyDir 마운트
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
  seccompProfile:
    type: RuntimeDefault
```

---

### 2-3. `latest` 태그 사용 (이미지 불변성 위반)

| 이미지 | 위치 |
|--------|------|
| `bitnami/postgresql:latest` | apps/postgresql-0 |
| `bitnami/redis:latest` | infisical/redis |
| `ghcr.io/immich-app/immich-server:release` | immich/server |
| `ghcr.io/immich-app/immich-machine-learning:release` | immich/ml |

**위험:** `latest`/`release` 태그는 언제든 내용이 바뀔 수 있어 재현 불가능한 배포, 예기치 않은 breaking change, 롤백 불가 등의 문제 발생.

**권장:** 모든 이미지에 구체적 버전 태그 사용 (e.g., `bitnami/postgresql:16.6.0`, `immich-server:v1.131.3`). Renovate가 자동으로 버전 업데이트 PR을 생성해줌.

---

### 2-4. Tailscale Operator OAuth 미설정

**파일:** `argocd/applications/tailscale-operator.yaml` - auto-sync 비활성화 상태
**파일:** `k8s/base/tailscale-operator/values.yaml` - clientId/clientSecret 빈 값

Tailscale Operator가 비활성 상태. `tailscale-only` Middleware는 IP 범위(100.64.0.0/10)로만 필터링 중이며, Tailscale Operator 자체는 동작하지 않음.

---

## 3. 안정성 개선점

### 3-1. Startup Probe 미설정 (8개 워크로드)

Startup Probe가 없으면 컨테이너 초기화가 느릴 때 liveness probe가 먼저 실패하여 불필요한 재시작이 발생할 수 있음.

| 워크로드 | liveness | readiness | startup |
|----------|----------|-----------|---------|
| cloudflared | O | O | **X** |
| dozzle | O | O | **X** |
| portainer | O | O | **X** |
| adguard | O | O | **X** |
| uptime-kuma | O | O | **X** |
| homepage | O | O | **X** |
| immich-postgres | O | O | **X** |
| immich-redis | O | O | **X** |

**잘 설정된 예시:** api-server, immich-server, immich-ml은 3가지 프로브 모두 설정됨.

**권장:** 초기화가 느린 서비스(PostgreSQL, ML 모델 로딩 등)에 우선적으로 startup probe 추가.

---

### 3-2. PodDisruptionBudget 부족

**현재 PDB 설정:** adguard, uptime-kuma, postgresql, infisical-redis (4개)

**PDB 미설정 주요 서비스:**
- **immich-postgres** - 데이터베이스 중단 시 데이터 손실 위험
- **immich-server** - 사진 업로드/접근 중단
- **traefik** - 전체 인그레스 중단 (가장 치명적)
- **cloudflared** - 외부 접근 전면 중단

**권장:** 최소한 traefik, cloudflared, immich-postgres에 PDB 추가.

---

### 3-3. 메모리 사용률 70% (노드 수준)

```
orbstack   CPU 810m (8%)   Memory 5,672Mi (70%)
```

Memory requests 합계는 ~5.7Gi이나 실제 사용량이 70%에 도달. OrbStack VM 메모리 할당이 8Gi 수준으로 보임.

**위험:** OOM Kill 발생 가능성. 특히 Immich ML이 모델 로딩 시 burst 메모리 사용.

**권장:**
- OrbStack VM 메모리 할당량을 10-12Gi로 증가 검토
- `immich-ml` limit 1280Mi가 실제 사용량 대비 적절한지 모니터링
- Prometheus 메트릭으로 실제 메모리 사용 패턴 분석 후 right-sizing

---

## 4. 리소스 & 성능 최적화

### 4-1. Dozzle 제거 확인

최근 커밋(`ab18a6b`)에서 Dozzle 제거를 의도했으나, production kustomization에서 확인 필요. Loki + Promtail이 이미 로그 수집을 수행하므로 Dozzle은 중복.

---

### 4-2. Renovate 규칙 누락

현재 `renovate.json`에 누락된 패키지:
- `infisical` (최근 추가된 서비스)
- `postgresql` / `bitnami/postgresql` (critical 분류 필요)
- `crowdsec` (보안 컴포넌트)
- `reloader` (인프라)
- `argocd` (인프라, 현재 v3.3.5)
- `restic` (백업)
- `busybox` (init container)

**권장:** 아래 규칙 추가:
```json
{
  "description": "Secret management - manual merge",
  "matchPackagePatterns": ["infisical", "reloader"],
  "automerge": false,
  "labels": ["critical", "dependencies"]
},
{
  "description": "Database - manual merge only",
  "matchPackagePatterns": ["postgresql", "redis"],
  "automerge": false,
  "labels": ["critical", "dependencies"]
}
```

---

### 4-3. ArgoCD 리소스 최적화

ArgoCD의 5개 컴포넌트가 상당한 리소스를 소비:
- Application Controller: 100m/256Mi ~ 500m/768Mi
- Repo Server: 50m/128Mi ~ 500m/256Mi
- Server: 50m/64Mi ~ 300m/256Mi
- ApplicationSet Controller, Redis, Image Updater

단일 노드에서 ArgoCD의 총 리소스 요청이 ~375m CPU, ~672Mi Memory. 소규모 homelab에서는 과할 수 있음.

**권장:** ArgoCD Application Controller의 `--self-heal-timeout`, `--repo-server-timeout` 튜닝으로 불필요한 reconciliation 줄이기.

---

## 5. 백업 & 재해복구 점검

### 5-1. 현재 백업 상태 (양호)

| 대상 | 방식 | 주기 | 보존 | 오프사이트 | 상태 |
|------|------|------|------|-----------|------|
| Immich Media | Restic | 매일 03:00 KST | 7일/4주/6월 | R2 | **양호** |
| Immich DB | pg_dump + Restic | 매일 03:00 KST | 7일 | R2 | **양호** |
| PostgreSQL (api+infisical) | pg_dump CronJob | 매일 03:00 KST | 7일 | **없음** | **개선 필요** |
| PVC (AdGuard, UptimeKuma 등) | backup.sh (수동) | 수동 실행 | 7회분 | **없음** | **개선 필요** |
| Prometheus TSDB | **없음** | - | - | - | **미구현** |
| Grafana 대시보드 | **없음** | - | - | - | **미구현** |
| Loki 로그 | **없음** | - | - | - | **미구현** |

### 5-2. 개선 필요 항목

**A. PostgreSQL (api+infisical) 오프사이트 백업 없음**
- 현재 로컬 PVC에만 백업. 디스크 장애 시 백업도 함께 유실.
- **권장:** Immich처럼 R2 또는 다른 오프사이트 스토리지에 추가 백업.

**B. backup.sh 자동화 없음**
- 수동 `make backup` 실행에 의존. 실행을 잊으면 백업 공백 발생.
- **권장:** CronJob으로 자동화하거나, 최소 crontab에 등록.

**C. 백업 복원 테스트 미수행**
- DR 문서(`docs/disaster-recovery.md`)는 잘 작성되어 있으나, 실제 복원 테스트 기록이 없음.
- **권장:** 분기 1회 복원 테스트 수행 및 결과 기록.

**D. Infisical ENCRYPTION_KEY 백업 확인**
- DR 문서에 명시되어 있으나, 실제 외부 백업 여부 확인 필요.
- 이 키를 잃으면 모든 시크릿 복구 불가.

---

## 6. CI/CD & GitOps 개선

### 6-1. ArgoCD Multi-Source 구성 불안정

Traefik과 Tailscale Operator가 multi-source(Helm + Kustomize)로 구성되어 있는데, 이 조합에서 env 머지 충돌이 발생 중.

**권장:**
- Helm 차트의 부가 리소스(Middleware, IngressRoute)는 별도 ArgoCD Application으로 분리
- 또는 Helm postRenderer로 Kustomize 적용

### 6-2. App-of-Apps에서 누락된 Application

`argocd/applications/` 디렉토리에 있는 앱 목록과 실제 배포된 서비스 비교:

| 서비스 | ArgoCD App | 배포 상태 |
|--------|-----------|----------|
| monitoring (prometheus+grafana+loki) | **없음** | 배포됨 |
| infisical | **없음** | 배포됨 |
| crowdsec | **없음** | 배포됨 (직접?) |
| postgresql | **없음** | 배포됨 |
| reloader | **없음** | 배포됨 |

이 서비스들이 ArgoCD 외부에서 수동 배포된 것으로 보임. GitOps 원칙에 위배.

**권장:** 모든 서비스를 ArgoCD Application으로 관리. 특히 monitoring, infisical, postgresql은 Helm 차트 기반이므로 ArgoCD Application 정의 추가 필요.

### 6-3. Immich 이미지 `release` 태그의 Image Updater 호환성

Immich는 `release` 태그를 사용 중인데, ArgoCD Image Updater는 semver 기반 태그 업데이트에 최적화. `release` 태그는 mutable이므로 Image Updater가 변경을 감지하지 못할 수 있음.

**권장:** Immich를 특정 버전 태그(e.g., `v1.131.3`)로 전환하고 Renovate로 업데이트 관리.

---

## 7. 추가 추천 서비스

### 7-1. 높은 가치 (리소스 대비 효용 높음)

#### A. Cert-Manager (Let's Encrypt 관리 표준화)

현재 Traefik 내장 ACME를 사용 중이나, cert-manager는 K8s 생태계 표준.

**장점:**
- Certificate CRD로 인증서를 선언적 관리
- 와일드카드 인증서를 여러 IngressRoute에서 공유
- Traefik 재시작/재배포 시에도 인증서 안전
- 인증서 갱신 모니터링 + AlertManager 연동

**리소스:** ~50m CPU, ~64Mi Memory
**난이도:** 낮음

---

#### B. Longhorn 또는 OpenEBS (분산 스토리지)

현재 모든 PV가 hostPath 기반. 노드 장애 시 데이터 접근 불가.

**장점:**
- 스냅샷 기반 백업/복원
- PVC 레벨 데이터 보호
- 향후 멀티 노드 확장 시 필수

**리소스:** ~200m CPU, ~256Mi Memory
**난이도:** 중간 (단일 노드에서는 오버헤드만 증가할 수 있으므로, 멀티 노드 계획이 있을 때 도입 권장)

---

#### C. Kyverno 또는 OPA Gatekeeper (정책 엔진)

securityContext 누락, latest 태그 사용 등을 자동으로 차단/경고.

**장점:**
- `latest` 태그 사용 시 배포 차단
- securityContext 미설정 시 경고/차단
- 리소스 limits 미설정 시 차단
- NetworkPolicy 없는 네임스페이스 감지

**리소스:** ~100m CPU, ~128Mi Memory
**난이도:** 중간

---

#### D. Grafana Alloy (통합 텔레메트리 수집기)

현재 Promtail이 로그만 수집. Grafana Alloy는 메트릭, 로그, 트레이스를 하나의 에이전트로 수집.

**장점:**
- Promtail을 대체하면서 추가 기능 제공
- OpenTelemetry 호환 (향후 트레이싱 추가 용이)
- Prometheus remote_write 지원

**리소스:** Promtail과 유사 (~50m CPU, ~64Mi)
**난이도:** 낮음

---

### 7-2. 중간 가치 (특정 니즈에 따라)

#### E. Goldilocks (리소스 Right-Sizing 자동 추천)

VPA(Vertical Pod Autoscaler) 기반으로 각 워크로드의 적정 리소스를 추천하는 대시보드.

**장점:** 메모리 70% 사용 상태에서 최적화 포인트를 데이터 기반으로 제시.
**리소스:** ~50m CPU, ~64Mi Memory

---

#### F. Velero (클러스터 레벨 백업/복원)

현재 CronJob + backup.sh 조합 대신, 클러스터 전체를 스냅샷으로 백업.

**장점:**
- 네임스페이스 단위 백업/복원
- PVC 스냅샷 + 메타데이터 백업
- 클러스터 마이그레이션 지원
- R2/S3 오프사이트 백업

**리소스:** ~100m CPU, ~128Mi Memory
**난이도:** 중간

---

#### G. Authelia / Authentik (SSO & 2FA)

현재 각 서비스별 개별 인증. 통합 SSO 게이트웨이.

**장점:**
- 단일 로그인으로 모든 내부 서비스 접근
- 2FA/WebAuthn 지원
- Traefik ForwardAuth Middleware 연동

**리소스:** ~100m CPU, ~128Mi Memory
**난이도:** 중간~높음

---

#### H. Ntfy 또는 Gotify (셀프호스트 알림)

현재 Telegram Bot + Moshi(curl webhook)로 알림. 셀프호스트 알림 서비스 추가.

**장점:**
- 외부 서비스 의존성 제거
- 모바일 앱 + 웹 UI
- AlertManager, CronJob, 다양한 소스에서 통합 알림
- API 기반으로 자동화 연동 용이

**리소스:** ~25m CPU, ~32Mi Memory
**난이도:** 낮음

---

### 7-3. 향후 고려 (멀티노드/확장 시)

| 서비스 | 용도 | 도입 시점 |
|--------|------|----------|
| MetalLB | 로드밸런서 (베어메탈) | OrbStack 외부 K8s 전환 시 |
| Cilium | eBPF 기반 네트워킹 + 보안 | K3s → K8s 전환 시 |
| Harbor | 프라이빗 컨테이너 레지스트리 | GHCR 대체 또는 미러 필요 시 |
| Linkerd / Istio | 서비스 메시 | 마이크로서비스 간 mTLS 필요 시 |
| Dex | OIDC 프로바이더 | ArgoCD + 다중 서비스 SSO 시 |

---

## 8. 우선순위 로드맵

### Phase A: 긴급 수정 (이번 주)

- [ ] **Traefik Helm values env 충돌 해결** → ArgoCD sync 정상화
- [ ] **CrowdSec LAPI Key를 Secret으로 이동** + 키 회전
- [ ] **Homepage 중복 파드 정리** 확인
- [ ] **Image Updater targetNamespace 수정** → 재시작 루프 해소

### Phase B: 보안 강화 (1~2주)

- [ ] `argocd`, `infisical`, `actions-runner-system` NetworkPolicy 추가
- [ ] Immich 전체 워크로드 + api-server에 securityContext 추가
- [ ] `latest`/`release` 태그 → 고정 버전 태그로 전환
- [ ] Renovate 규칙에 누락 패키지 추가

### Phase C: 안정성 개선 (2~4주)

- [ ] ArgoCD Application 추가 (monitoring, infisical, postgresql, reloader, crowdsec)
- [ ] Traefik, Cloudflared, Immich-Postgres에 PDB 추가
- [ ] PostgreSQL 오프사이트 백업 구성 (R2)
- [ ] backup.sh CronJob 자동화
- [ ] 주요 워크로드 Startup Probe 추가

### Phase D: 추가 서비스 (1~2개월)

- [ ] Kyverno 도입 (정책 기반 보안 자동화)
- [ ] Goldilocks 도입 (리소스 최적화)
- [ ] cert-manager 도입 검토 (Traefik ACME → cert-manager 전환)
- [ ] 백업 복원 테스트 수행 및 문서화

---

## 부록: 현재 서비스 전체 맵

```
                        ┌─────── Internet ────────┐
                        │                          │
                   Cloudflare                  Tailscale
                   (WAF/CDN)                    (VPN)
                        │                          │
                   Cloudflared                     │
                   Tunnel                          │
                        │                          │
                   ┌────┴────── Traefik ──────────┘
                   │        (v3.3, ACME, CrowdSec)
                   │
          ┌────────┼────────────────────────┐
          │        │                        │
     [Public]   [Tailscale Only]      [Internal]
          │        │                        │
     Immich    Homepage              ArgoCD
     (photos)  AdGuard              Infisical
               Uptime Kuma          Prometheus
               Portainer            Grafana
               Grafana              Loki
               API Server           PostgreSQL
               Traefik Dashboard    CrowdSec
               Infisical

     ┌── Backup ───────────────────────────┐
     │ Immich: Restic → Local + R2 (daily) │
     │ PostgreSQL: pg_dump → PVC (daily)   │
     │ PVCs: backup.sh → local (manual)    │
     └────────────────────────────────────┘

     ┌── Monitoring ───────────────────────┐
     │ Prometheus → Grafana (metrics)      │
     │ Loki + Promtail (logs)              │
     │ AlertManager → Telegram (alerts)    │
     │ Uptime Kuma (availability)          │
     └────────────────────────────────────┘

     ┌── CI/CD ────────────────────────────┐
     │ GitHub → ARC Runner → GHCR         │
     │ ArgoCD (GitOps sync)               │
     │ Image Updater (auto deploy)        │
     │ Argo Rollouts (blue-green)         │
     │ Renovate (dependency updates)      │
     └────────────────────────────────────┘
```
