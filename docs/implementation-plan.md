# Homelab 통합 구현 계획

> 작성일: 2026-03-24

---

## 전체 구현 항목 요약

| Phase | 항목 | 분류 | 트리거 |
|-------|------|------|--------|
| 1 | Prometheus + Grafana + Loki + AlertManager | 관측성 | 즉시 |
| 1.5 | Renovate (자동 의존성 업데이트) | CI/CD | 즉시 |
| 2 | GHCR + GitHub Actions + Trivy | CI/CD | API 서버 개발 시 |
| 3 | Argo Rollouts 확장 + PostgreSQL + pgdump | 배포/DB | API 서버 개발 시 |
| 4 | Infisical + Reloader | 시크릿 | PostgreSQL 안정 후 |
| 5 | Analysis Template (자동 롤백) | 배포 | Prometheus 1주일+ |
| S | **Immich + 외장 SSD (파일/이미지 서버)** | **스토리지/서비스** | **즉시 가능 (SSD 확보 완료)** |
| | — 외장 NVMe SSD 구성 (TB4, APFS) | 스토리지 | |
| | — Immich 스택 배포 (Server, ML, PostgreSQL, Redis) | 서비스 | |
| | — 백업 자동화 (Restic + R2) | 데이터 보호 | |
| 6 | **공개 서비스 보안 + 자동화** | **보안/네트워크** | **첫 공개 서비스 도입 시** |
| | — External DNS (서브도메인 자동 등록) | 네트워크 | |
| | — Cloudflare 기본 보안 (WAF, Rate Limit, Bot Fight) | 보안 | |
| | — CrowdSec + Traefik Bouncer | 보안 | |
| | — Cloudflare Bouncer (선택) | 보안 | |

---

## 의존성 맵

```
Prometheus + Loki + AlertManager (Phase 1) ────────────────────────────────┐
Renovate (Phase 1.5, 병렬 가능)                                             │
Immich + 외장 SSD (Phase S, 병렬 가능) ───────────────────────────────────┐ │ 1주일+ 데이터
  └→ Phase S AlertManager 규칙은 Phase 1 이후                             │ │
                  ┌───────────────────────────────────────────────────────┤ │
                  │                                                       │ │
API 서버 개발 ────┤                                                       │ │
                  ├─→ GHCR + Trivy (Phase 2) ─→ Image Updater ─→ Rollout ─→ Analysis Template
                  │                                               (Phase 3)  (Phase 5)
                  └─→ PostgreSQL API용 (Phase 3)
                            │
                            ▼
                       Infisical + Reloader (Phase 4)
                            │
                            └→ Immich 시크릿도 Infisical에 등록

즉시 (SSD 확보 완료) ──────────────────────────────────────────────────────
  Immich + 외장 SSD 구성 + 백업 자동화 (Phase S)
  Phase 1과 병렬 가능 (단, AlertManager 규칙은 Phase 1 이후)
  상세: docs/immich-backup-analysis.md

첫 공개 서비스 도입 시 ────────────────────────────────────────────────────
  External DNS + Cloudflare 보안 + CrowdSec + Cloudflare Bouncer (Phase 6)
```

> **참고:** GHCR과 PostgreSQL은 모두 API 서버 개발의 산물이지, 서로 의존하지 않는다. 병렬 진행 가능.
> **현재 공개 서비스 0개.** Phase 6은 첫 공개 서비스 도입과 동시에 진행.

---

## 구현 순서

### Phase 1 — Prometheus + Grafana + Loki + AlertManager

> 소요: 반나절~1일 | 리소스: CPU 600m, Memory ~1.18Gi, Storage 23Gi | 선행 조건: 없음
> 관측성 공백 해소. Phase 5 Analysis Template의 메트릭 기반, Phase 6 CrowdSec 모니터링의 기반.

- [ ] `monitoring` namespace 생성
- [ ] kube-prometheus-stack Helm 차트 배포
  - K3s 호환: `kubeEtcd`, `kubeScheduler`, `kubeProxy`, `kubeControllerManager` 비활성화
  - Prometheus TSDB: PVC 10Gi, 보존 30일
  - Grafana: PVC 2Gi
  - ArgoCD: `ServerSideApply=true` (CRD 크기 문제)
- [ ] ArgoCD Application 추가 (`argocd/applications/monitoring.yaml`)
- [ ] IngressRoute 생성 (`grafana.ukkiee.dev`, tailscale-only + security-headers)
- [ ] Grafana admin 비밀번호 SealedSecret으로 관리

**1-B. AlertManager 알림 채널 설정 (Telegram)**
- [ ] Telegram Bot 생성 (@BotFather → `/newbot`)
- [ ] Chat ID 확인 (@userinfobot 또는 getUpdates API)
- [ ] AlertManager `alertmanager.config`에 Telegram receiver 설정
  ```yaml
  alertmanager:
    config:
      receivers:
        - name: telegram
          telegram_configs:
            - bot_token: "<BOT_TOKEN>"  # SealedSecret으로 관리
              chat_id: <CHAT_ID>
              parse_mode: HTML
              message: |
                {{ range .Alerts }}
                <b>{{ .Labels.alertname }}</b>
                {{ .Annotations.summary }}
                Severity: {{ .Labels.severity }}
                {{ end }}
      route:
        receiver: telegram
        group_wait: 30s
        group_interval: 5m
        repeat_interval: 4h
  ```
- [ ] Bot Token을 SealedSecret으로 관리 (또는 향후 Infisical)
- [ ] 기본 알림 규칙 활성화
  - Pod CrashLoopBackOff
  - Node 메모리/디스크 부족 (>85%)
  - Pod OOMKilled
  - PVC 용량 부족 (>80%)
  - Target Down (scrape 실패)
- [ ] 테스트 알림 발송 확인

**1-C. Loki + Promtail (로그 집계)**
- [ ] Loki Helm 차트 배포 (single binary 모드, Homelab에 적합)
  - PVC 10Gi (로그 보존), 보존 기간: 30일
  - CPU 100m/500m, Memory 256Mi/512Mi
- [ ] Promtail DaemonSet 배포 (각 노드에서 컨테이너 로그 수집)
  - CPU 50m/200m, Memory 64Mi/128Mi
- [ ] Grafana에 Loki 데이터소스 추가
- [ ] Grafana Explore에서 로그 검색 동작 확인
- [ ] CrowdSec 탐지 로그도 Loki로 수집되는지 확인 (Phase 6 이후)

**1-D. NetworkPolicy + 기타**
- [ ] NetworkPolicy 추가
  - `monitoring` namespace default deny (ingress + egress)
  - Prometheus → 모든 namespace scrape 허용 (egress)
  - Grafana → Prometheus, Loki 쿼리 (egress)
  - Promtail → Loki (egress)
  - Traefik → Grafana (ingress, IngressRoute)
  - Prometheus → DNS (egress, port 53)
- [ ] Traefik metrics 활성화 (`metrics.prometheus` in values.yaml)
- [ ] Cloudflared PodMonitor 추가 (이미 `--metrics 0.0.0.0:2000` 설정됨)
- [ ] 기본 대시보드 확인 (cAdvisor, Node, Pod, Loki 로그 등)
- [ ] `backup.sh`에 Prometheus TSDB + Grafana PVC 백업 대상 추가

**리소스:** CPU 600m request, Memory ~1.18Gi request, Storage 23Gi

**검증:** Grafana에서 메트릭 수집 + 로그 검색 + 알림 수신 모두 정상이면 완료

---

### Phase 1.5 — Renovate (자동 의존성 업데이트)

> 소요: ~30분 | 리소스: 0 (GitHub App 사용) | 선행 조건: 없음 (Phase 1과 병렬 가능)
> Helm 차트, 컨테이너 이미지 버전 업데이트 PR을 자동 생성. ArgoCD와 궁합이 좋음.

- [ ] GitHub App "Mend Renovate" 설치 (https://github.com/apps/renovate)
  - 또는 Self-hosted Renovate를 ARC Runner CronJob으로 실행 (리소스: 50m CPU, 128Mi, 비상주)
- [ ] 기존 `renovate.json` 설정 확인 (이미 존재함) 및 필요 시 업데이트
- [ ] 첫 PR 생성 확인 (Dependency Dashboard Issue)
- [ ] 자동 머지 규칙 설정 (patch 버전은 자동, minor/major는 수동 리뷰)

**검증:** Renovate가 Helm 차트/이미지 버전 업데이트 PR을 자동 생성

---

### Phase 2 — GHCR + CI/CD 파이프라인

> 소요: 2~3시간 | 리소스: 0 (ARC Runner 기 배포) | 선행 조건: 배포할 자체 앱(API 서버 등) 존재
> API 서버 개발 시작 시점에 함께 진행.

**2-A. GitHub Actions Workflow**
- [ ] `.github/workflows/` 디렉토리 생성
- [ ] 앱별 빌드 + GHCR push 워크플로 작성
  - 태그: `ghcr.io/ukkiee-dev/<app>:latest` + `ghcr.io/ukkiee-dev/<app>:<sha>`
- [ ] GHCR 로그인: `GITHUB_TOKEN` 사용
- [ ] Trivy 이미지 취약점 스캔 스텝 추가
  ```yaml
  - name: Scan image for vulnerabilities
    uses: aquasecurity/trivy-action@master
    with:
      image-ref: ghcr.io/ukkiee-dev/${{ env.APP }}:${{ github.sha }}
      severity: CRITICAL,HIGH
      exit-code: 1  # CRITICAL/HIGH 발견 시 빌드 실패
  ```
- [ ] ARC Runner에서 워크플로 실행 확인

**2-B. imagePullSecret (private repo인 경우)**
- [ ] GHCR pull용 `docker-registry` Secret 생성
- [ ] SealedSecret으로 관리
- [ ] ServiceAccount에 imagePullSecret 연결

**2-C. ArgoCD Image Updater**
- [ ] ArgoCD Image Updater Helm 차트 배포
- [ ] ArgoCD Application 추가 (`argocd/applications/image-updater.yaml`)
- [ ] 대상 Application에 Image Updater 어노테이션 추가
- [ ] GHCR 레지스트리 인증 설정
- [ ] 이미지 태그 변경 → ArgoCD 자동 동기화 확인

**검증:** 코드 push → GHCR에 새 태그 → ArgoCD가 자동으로 이미지 업데이트

---

### Phase 3 — Argo Rollouts 신규 앱 적용 + PostgreSQL

> 소요: 2~4시간 | 선행 조건: Phase 2 완료 (GHCR 파이프라인 동작)
> API 서버 배포와 함께 Rollout 리소스 적용. PostgreSQL은 API 서버의 DB.

**3-A. 신규 앱 Rollout 적용**
- [ ] Deployment 대신 Rollout 리소스 사용
  - `activeService` + `previewService` 구성
  - 초기: `autoPromotionEnabled: false` (수동 승인)
- [ ] preview IngressRoute 구성 (`preview-<app>.ukkiee.dev`, tailscale-only)
- [ ] 수동 promote/abort 흐름 테스트

**3-B. PostgreSQL 배포 (API 서버용)**
- [ ] PostgreSQL Helm 차트 배포 (Bitnami 또는 CloudNativePG)
- [ ] API 서버용 database 생성
- [ ] Infisical용 database 사전 생성 (Phase 4 대비)

**3-C. PostgreSQL 백업 자동화**
- [ ] pgdump CronJob 매니페스트 작성
  - 스케줄: 매일 03:00 KST (`0 18 * * *` UTC)
  - 보존: 최근 7일
  - 백업 위치: PVC 또는 외부 저장소
- [ ] 복원 테스트 수행 (pgdump → psql 복원 검증)
- [ ] `backup.sh`에 PostgreSQL 백업 상태 확인 로직 추가

**검증:** blue/green 슬롯 전환 확인, PostgreSQL 접속 정상, pgdump CronJob 성공

---

### Phase 4 — Infisical 시크릿 관리 플랫폼

> 소요: 4~8시간 | 리소스: CPU 500m, Memory 768Mi, Storage 1Gi (Redis) | 선행 조건: Phase 3-B (PostgreSQL)
> PostgreSQL이 이미 있으므로 DB 공유. Redis만 추가.

**4-A. Infisical 인프라 배포**
- [ ] `infisical` namespace 생성
- [ ] Redis Helm 차트 배포 (Bitnami, standalone)
  - 100m CPU, 256Mi Memory, PVC 1Gi
- [ ] Infisical Helm 차트 배포 (`infisical-standalone`)
  - DB_CONNECTION_URI: Phase 3-B의 PostgreSQL (별도 database)
  - ENCRYPTION_KEY 생성 + **클러스터 외부 안전한 곳에 백업**
  - SITE_URL: `secrets.ukkiee.dev`
- [ ] ArgoCD Application 추가 (`argocd/applications/infisical.yaml`)
- [ ] IngressRoute 생성 (`secrets.ukkiee.dev`, tailscale-only + security-headers)
- [ ] NetworkPolicy 추가
  - `infisical` namespace default deny (ingress + egress)
  - Infisical → PostgreSQL (egress)
  - Infisical → Redis (egress)
  - Infisical → DNS (egress, port 53)
  - Traefik → Infisical (ingress, IngressRoute)
  - Infisical Operator → Infisical API (ingress)

**4-B. Reloader 배포 (ConfigMap/Secret 변경 감지)**
- [ ] Stakater Reloader Helm 차트 배포 (`stakater/reloader`)
  - CPU 25m/100m, Memory 64Mi/128Mi
- [ ] ArgoCD Application 추가 (`argocd/applications/reloader.yaml`)
- [ ] 기존 Deployment/StatefulSet/Rollout에 Reloader 어노테이션 추가
  - `reloader.stakater.com/auto: "true"` (ConfigMap + Secret 변경 모두 감지)
- [ ] Homepage ConfigMap 변경 → Pod 자동 재시작 테스트

**4-C. Infisical Operator 배포**
- [ ] Infisical Secrets Operator Helm 차트 배포
- [ ] Kubernetes Auth 설정
- [ ] ServiceAccount + ClusterRole 확인

**4-D. 시크릿 마이그레이션**
- [ ] Infisical 프로젝트 `homelab` + 환경 `production` 생성
- [ ] 전체 시크릿 Infisical에 등록 (기존 6개 + Phase 1~3에서 추가된 시크릿)
  - 기존 (6개): traefik, traefik-dashboard-auth, cloudflare-tunnel-token, portainer, adguard, arc-runner-github-token
  - Phase 1 추가: Grafana admin 비밀번호
  - Phase 2 추가: GHCR imagePullSecret (private repo인 경우)
  - Phase 3 추가: PostgreSQL 접속 정보
  - 누락 보완: Tailscale OAuth 시크릿 (`clientId`, `clientSecret`)
- [ ] InfisicalSecret CRD 매니페스트 작성 (namespace별)
- [ ] 각 CRD `resyncInterval: 60s` 설정

**4-E. 검증 및 전환**
- [ ] InfisicalSecret으로 생성된 K8s Secret 확인
- [ ] 전 서비스 정상 동작 확인 (Traefik, Cloudflared, Homepage, AdGuard, Portainer, ARC)
- [ ] Pod `auto-reload` 어노테이션 추가
- [ ] 시크릿 변경 → Pod 자동 재시작 테스트

**기존 시스템 제거**
- [ ] SealedSecrets Controller 제거
- [ ] SealedSecret YAML 파일 삭제
- [ ] `scripts/bootstrap-secrets.sh` → Infisical CLI 기반 재작성
- [ ] `scripts/seal-secret.sh` 제거
- [ ] Makefile의 seal-secret, bootstrap-secrets 타겟 업데이트
- [ ] GHCR imagePullSecret을 Infisical로 마이그레이션 (Phase 2에서 SealedSecret으로 생성한 경우)

**주의:** Infisical 자체의 부트스트랩 시크릿(ENCRYPTION_KEY, AUTH_SECRET, DB_CONNECTION_URI, REDIS_URL)은 Infisical로 관리할 수 없음. 수동 `kubectl create secret` 또는 Helm 차트 자동 생성으로 처리. `scripts/bootstrap-secrets.sh` 재작성 시 이 항목 포함.

**검증:** 모든 서비스 정상 동작 + SealedSecrets 완전 제거

---

### Phase 5 — Analysis Template (자동 롤백)

> 소요: 2~3시간 | 리소스: 0 | 선행 조건: Prometheus 1주일+ 데이터, Phase 3-A (Rollout 앱)
> Prometheus 메트릭 기반 자동 검증으로 완전 자동화된 무중단 배포 완성.

- [ ] Grafana Explore에서 baseline 메트릭 확인 (1주일+ 데이터)
  ```promql
  sum(rate(http_requests_total{status!~"5.."}[5m]))
  /
  sum(rate(http_requests_total[5m]))
  ```
- [ ] AnalysisTemplate 리소스 작성
  - Prometheus address: `http://prometheus-kube-prometheus-prometheus.monitoring:9090`
  - 성공률 >= 0.95, interval 5m, count 3, failureLimit 1
- [ ] Rollout에 `prePromotionAnalysis` 연결
- [ ] 정상 이미지 배포 → 자동 promote 테스트
- [ ] 에러 이미지 의도 배포 → 자동 rollback 테스트
- [ ] `autoPromotionEnabled: true`로 전환
- [ ] Homepage Rollout에도 Analysis Template 적용 (기존 30초 autoPromotion 대체)

**주의:** 메트릭이 부족한 상태에서 threshold 설정 시 오탐 롤백 빈발. 반드시 1주일+ 데이터 확인 후 설정.

**검증:** 에러 이미지 배포 시 자동 롤백 확인

---

### Phase 6 — 공개 서비스 보안 + 자동화 (첫 공개 서비스 도입 시)

> 소요: 반나절~1일 | 선행 조건: 공개할 서비스가 존재
> 서브도메인 자동 등록 + Cloudflare 보안 + CrowdSec 행동 분석을 한 번에 구축.
> 상세 분석: `docs/crowdsec-traefik-bouncer-analysis.md`

**6-A. External DNS (서브도메인 자동 등록)**
- [ ] Cloudflare Tunnel이 새 서브도메인을 처리하는지 확인 (와일드카드 `*.ukkiee.dev` 또는 catch-all 설정)
- [ ] External DNS Helm 차트 배포
  - provider: cloudflare
  - source: traefik (IngressRoute CRD 감시)
  - Cloudflare API 토큰 (DNS 편집 권한, 기존 traefik 토큰과 분리 권장)
  - `txtOwnerId`: 클러스터 식별자 (다른 DNS 레코드와 충돌 방지)
  - policy: `sync` (IngressRoute 삭제 시 DNS 레코드도 삭제)
- [ ] ArgoCD Application 추가 (`argocd/applications/external-dns.yaml`)
- [ ] NetworkPolicy 추가 (external-dns → internet:443, DNS)
- [ ] IngressRoute에 어노테이션으로 공개/비공개 제어
  ```yaml
  # 공개 서비스 (External DNS가 Cloudflare DNS 레코드 자동 생성)
  annotations:
    external-dns.alpha.kubernetes.io/hostname: api.ukkiee.dev
    external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"

  # Tailscale 전용 서비스 (어노테이션 없음 → DNS 레코드 미생성)
  ```
- [ ] 테스트: 공개 IngressRoute 생성 → Cloudflare DNS 레코드 자동 생성 확인

**6-B. Cloudflare 기본 보안**
- [ ] Cloudflare WAF Managed Rules 활성화 (OWASP Core Ruleset)
- [ ] Cloudflare Bot Fight Mode 활성화
- [ ] Cloudflare Rate Limiting Rule 설정 (공개 서비스 경로, 분당 제한)
- [ ] Traefik Rate Limit Middleware 추가 (공개 IngressRoute)
  - `sourceCriterion`: `CF-Connecting-IP` 헤더 기반

**6-C. CrowdSec + Traefik Bouncer**
- [ ] CrowdSec Bouncer API Key 시크릿 관리 (Phase 4 완료 시 Infisical, 아니면 SealedSecret)
- [ ] `crowdsec` namespace 생성
- [ ] CrowdSec Helm 차트 배포 (Agent + LAPI)
  - `crowdsecurity/traefik`, `crowdsecurity/http-cve` collection
  - LAPI PVC 1Gi, CPU 50m/200m, Memory 128Mi/256Mi
- [ ] Traefik 액세스 로그 활성화 (JSON format, syslog → CrowdSec)
- [ ] Traefik Bouncer Plugin 설정
  - `CF-Connecting-IP` 헤더 기반, Tailscale CGNAT 신뢰 IP, `failOpen: true`
- [ ] NetworkPolicy 추가 (crowdsec namespace default deny, traefik→LAPI, crowdsec→internet)
- [ ] 공개 IngressRoute에 `crowdsec-bouncer` middleware 추가
- [ ] CrowdSec CAPI 등록 (커뮤니티 blocklist 구독)

**6-D. Cloudflare Bouncer (선택)**
- [ ] Cloudflare Bouncer Pod 배포
- [ ] CrowdSec 탐지 → Cloudflare 엣지에서 선제 차단 검증

**리소스:** External DNS ~50m CPU, 64Mi | CrowdSec 50m CPU, 138Mi, 1Gi

**검증:** IngressRoute 생성 → DNS 자동 등록 → Cloudflare WAF 동작 → CrowdSec 탐지/차단

---

## 타임라인 요약

```
즉시 ──────────────────────────────────────────────────────────────
│  Phase 1: Prometheus + Grafana + Loki + AlertManager (반나절~1일)
│  Phase 1.5: Renovate (30분, Phase 1과 병렬 가능)
│
API 서버 개발 시작 시 ─────────────────────────────────────────────
│  Phase 2: GHCR + CI/CD + Trivy (2~3시간)
│  Phase 3: Rollout + PostgreSQL + pgdump 백업 (2~4시간)
│
PostgreSQL 안정화 후 ──────────────────────────────────────────────
│  Phase 4: Infisical + Reloader + 마이그레이션 (4~8시간)
│
Prometheus 1주일+ 데이터 축적 후 ──────────────────────────────────
│  Phase 5: Analysis Template (2~3시간)
│
첫 공개 서비스 도입 시 ────────────────────────────────────────────
│  Phase 6: External DNS + Cloudflare 보안 + CrowdSec (반나절~1일)
```

---

## 리소스 누적 추이 (Mac Mini M4 기준)

| 시점 | CPU Request | Memory Request | 내장 Storage | 외장 Storage | M4 사용률 (16Gi) |
|------|-------------|----------------|:------------:|:------------:|-------------------|
| 현재 (VW 제거 후) | ~800m | ~0.9Gi | 6Gi | - | CPU 8%, Mem 6% |
| +Phase 1 (Prometheus + Loki + Promtail + AlertManager) | 1,400m | ~2.1Gi | 29Gi | - | CPU 14%, Mem 13% |
| +Phase 3 (PostgreSQL) | ~1,650m | ~2.6Gi | 39Gi | - | CPU 17%, Mem 16% |
| +Phase 4 (Infisical + Reloader) | ~2,175m | ~3.4Gi | 40Gi | - | CPU 22%, Mem 21% |
| **+Phase S (Immich)** | **~3,275m** | **~5.7Gi** | **56Gi** | **~1,750Gi** | **CPU 33%, Mem 36%** |
| +Phase 6 (External DNS + CrowdSec) | ~3,375m | ~5.9Gi | 57Gi | ~1,750Gi | CPU 34%, Mem 37% |
| **최종** | **~3,375m** | **~5.9Gi** | **~57Gi** | **~1,750Gi** | **CPU 34%, Mem 37%** |

> ML 추론은 burst 워크로드 (사진 업로드 시에만 CPU 집중). 평상시 idle 시 CPU ~15%, Mem ~30%.
> Phase S 상세: `docs/immich-backup-analysis.md`

---

## 주의사항 및 리스크

### Infisical 부트스트랩 닭과 달걀 문제

Phase 4에서 SealedSecrets를 제거하지만, Infisical 자체를 부팅하려면 아래 시크릿이 필요하다:
- `ENCRYPTION_KEY` (마스터 암호화 키)
- `AUTH_SECRET` (인증 키)
- `DB_CONNECTION_URI` (PostgreSQL 접속 정보)
- `REDIS_URL` (Redis 접속 정보)

**대응:** Infisical Helm 차트의 `existingSecret` 또는 Helm values로 주입. 이 "Infisical을 위한 시크릿"은 수동 `kubectl create secret`으로 생성하거나, bootstrap 스크립트에서 처리. ENCRYPTION_KEY는 반드시 클러스터 외부에 별도 백업.

### 기존 부트스트랩 시크릿 누락 보완

현재 `bootstrap-secrets.sh`에 누락된 시크릿:
- Tailscale OAuth 시크릿 (`clientId`, `clientSecret`) — values.yaml에 빈 값
- ARC Runner GitHub 토큰 — `seal-secret.sh`에는 있으나 `bootstrap-secrets.sh`에 미포함

**대응:** Phase 4의 Infisical 마이그레이션 시 이 누락분도 함께 등록하여 해결.

### Vaultwarden 제거 후 운영 주의

Vaultwarden-Kubernetes-Secrets가 동기화하던 시크릿(portainer, adguard)은 이제 SealedSecrets로 관리된다.
- `make bootstrap-secrets` 실행 시 portainer/adguard 시크릿도 생성됨
- Homepage Rollout이 `adguard` Secret을 참조하므로 (`HOMEPAGE_VAR_ADGUARD_USER/PASS`), 이 Secret이 존재해야 Homepage가 정상 동작
- 클러스터 재구축 시 반드시 `bootstrap-secrets.sh`를 먼저 실행

### Phase 간 병렬 실행 가능 여부

| 병렬 가능 조합 | 이유 |
|---------------|------|
| Phase 1 + Phase 1.5 + **Phase S** | 상호 독립 (모니터링 / GitHub / Immich) |
| Phase 2 + Phase 3 | GHCR과 PostgreSQL은 독립 (둘 다 API 서버의 산물) |
| Phase 5 + Phase 6 | Analysis Template과 공개 서비스 보안은 독립 |

| 병렬 불가 조합 | 이유 |
|---------------|------|
| Phase 3 → Phase 4 | Infisical이 PostgreSQL 의존 |
| Phase 1 → Phase 5 | Analysis Template이 Prometheus 1주일+ 데이터 의존 |
| Phase 4 검증 → 기존 시스템 제거 | 검증 완료 전 SealedSecrets 제거 금지 |
| Phase S AlertManager → Phase 1 | Immich 알림 규칙은 Prometheus 배포 후에만 가능 |

> **주의:** Phase S의 Immich PostgreSQL은 API 서버 PostgreSQL (Phase 3-B)과 **별도 인스턴스**. Immich는 벡터 확장(pgvecto.rs)이 필요하며 전용 이미지를 사용한다.

---

## 완성 아키텍처

```
코드 push
  → GitHub Actions (ARC Runner)
  → Trivy 취약점 스캔 (CRITICAL/HIGH 시 빌드 차단)     ← Phase 2
  → GHCR에 이미지 push
  → ArgoCD Image Updater 감지
  → Argo Rollouts green 배포
  → Analysis Template (Prometheus 메트릭 자동 검증)     ← Phase 5
      ├── 통과 → green active, blue 제거
      └── 실패 → blue 유지, green 롤백

의존성 관리
  → Renovate (Helm/이미지 버전 업데이트 PR 자동 생성)   ← Phase 1.5
  → 리뷰 후 머지 → ArgoCD 자동 배포

공개 서비스 자동화 (Phase 6 — 첫 공개 서비스 도입 시)
  IngressRoute + 어노테이션 추가
  → External DNS가 Cloudflare DNS CNAME 자동 생성
  → Cloudflare Tunnel로 트래픽 라우팅 (오리진 IP 비노출)
  → Cloudflare Edge (WAF + Rate Limit + Bot Fight)
  → CrowdSec Bouncer (행동 분석 + 커뮤니티 blocklist)
  → Cloudflare Bouncer (엣지 선제 차단, 선택)
  비공개 서비스: 어노테이션 없음 → DNS 미생성 → Tailscale only

시크릿
  → Infisical (중앙 관리 + 자동 동기화 + RBAC + 감사 로그) ← Phase 4
  → K8s Secret (InfisicalSecret CRD 동기화)
  → Reloader (ConfigMap/Secret 변경 시 Pod 재시작)      ← Phase 4

관측성
  → Prometheus (메트릭 수집)                            ← Phase 1
  → Loki + Promtail (로그 집계 + 검색)                  ← Phase 1
  → Grafana (메트릭 시각화 + 로그 검색 + 알림)           ← Phase 1
  → AlertManager → Telegram Bot (이상 알림)              ← Phase 1
  → Uptime Kuma (서비스 가용성 모니터링)                  ← 기존

데이터 보호
  → PostgreSQL pgdump CronJob (매일 03:00, 7일 보존)    ← Phase 3
  → PVC 백업 (backup.sh)                               ← 기존
  → Infisical ENCRYPTION_KEY 외부 백업                  ← Phase 4
  → 재해복구 절차서                                      ← docs/disaster-recovery.md
```
