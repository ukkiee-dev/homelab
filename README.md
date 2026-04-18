# Homelab

Mac Mini M4 위에서 OrbStack K3s를 사용하는 단일 노드 Kubernetes 홈랩.
ArgoCD 기반 GitOps로 모든 인프라와 애플리케이션을 선언적으로 관리한다.

## Architecture

```
Internet
  │
  ├─ Cloudflare Tunnel ──▶ Traefik (Ingress) ──▶ Public Services
  │                              │
  └─ Tailscale VPN ─────────────┘──▶ Internal Services

ArgoCD (App-of-Apps)
  ├─ infra/       ← sync-wave -1 (Infrastructure)
  ├─ apps/        ← sync-wave  0 (Applications)
  └─ monitoring/  ← sync-wave  1 (Observability)

GitHub Actions
  ├─ setup-app    ← 앱 온보딩 (Terraform DNS + Tunnel API + 매니페스트 생성)
  ├─ teardown     ← 앱 제거 (DNS/Tunnel/매니페스트/GHCR 정리)
  └─ audit        ← 주간 고아 앱 + Tunnel drift 감사
```

## Tech Stack

| Category | Tool |
|----------|------|
| Platform | Mac Mini M4 + OrbStack K3s |
| GitOps | ArgoCD (self-heal, auto-sync) |
| Ingress | Traefik v3 + Cloudflare DNS ACME |
| Tunnel | Cloudflared (public), Tailscale (internal) |
| DNS/IaC | Terraform + Cloudflare Provider v4 (R2 state backend) |
| Edge Security | Cloudflare WAF + Cache Rules + Security Headers |
| Secrets | Sealed Secrets (Bitnami) |
| Monitoring | VictoriaMetrics + VictoriaLogs + Grafana + Alloy |
| CI/CD | ARC (Actions Runner Controller) + GitHub Actions |
| Automation | setup-app (온보딩), teardown (제거), audit-orphans (감사) |
| Dependency | Renovate (auto-merge patch, Monday schedule) |

## Project Structure

```
.
├── argocd/
│   ├── root.yaml                 # App-of-Apps entry point
│   └── applications/
│       ├── infra/                # Infrastructure app definitions
│       ├── apps/                 # Application app definitions
│       └── monitoring/           # Monitoring app definitions
├── manifests/
│   ├── infra/
│   │   ├── argocd/              # ArgoCD Helm values
│   │   ├── traefik/             # Traefik Helm values + middlewares
│   │   ├── cloudflared/         # Cloudflare Tunnel deployment
│   │   ├── tailscale-operator/  # Tailscale Helm values
│   │   ├── arc-runners/         # GitHub Actions runner scale set
│   │   ├── sealed-secrets/      # Sealed Secrets Helm values
│   │   └── network-policies/    # Namespace NetworkPolicy rules
│   ├── apps/
│   │   ├── homepage/            # Service dashboard
│   │   ├── adguard/             # DNS ad blocker
│   │   ├── uptime-kuma/         # Uptime monitoring
│   │   ├── postgresql/          # Shared PostgreSQL + backup CronJob
│   │   └── test-web/            # CI/CD test application
│   └── monitoring/
│       ├── victoria-metrics/    # Metrics TSDB (30d retention)
│       ├── victoria-logs/       # Log store (15d retention)
│       ├── grafana/             # Dashboards + alerting
│       ├── alloy/               # Log/metric collector (DaemonSet)
│       ├── kube-state-metrics/  # Kubernetes object metrics
│       └── node-exporter/       # Host-level metrics (DaemonSet)
├── terraform/
│   ├── apps.json                # 앱 레지스트리 (서브도메인 매핑)
│   ├── dns.tf                   # Cloudflare CNAME 레코드
│   ├── waf.tf                   # WAF Custom Rules (5) + Rate Limiting (1)
│   ├── cache.tf                 # Cache Rules (정적 자산, API bypass)
│   ├── transform.tf             # Security response headers
│   ├── backend.tf               # R2 state storage
│   ├── provider.tf              # Cloudflare provider
│   └── variables.tf             # Input variables
├── .github/
│   ├── workflows/
│   │   ├── _update-image.yml    # 이미지 태그 갱신 (reusable)
│   │   ├── teardown.yml         # 앱 제거 자동화
│   │   └── audit-orphans.yml    # 주간 고아 앱 + Tunnel drift 감사
│   ├── actions/
│   │   └── setup-app/           # 앱 온보딩 composite action
│   └── scripts/
│       └── manage-tunnel-ingress.sh  # Tunnel API 관리 스크립트
├── docs/
│   └── disaster-recovery.md     # DR playbook (5 scenarios)
├── scripts/
│   ├── setup.sh                 # CLI tool installer + context setup
│   └── seal-secret.sh           # SealedSecret 관리 유틸리티
├── Makefile                     # Operational commands
├── backup.sh                    # PVC backup script
└── renovate.json                # Dependency update config
```

## Services

### Applications

| Service | Domain | Access | Description |
|---------|--------|--------|-------------|
| Test Web | `test-web.ukkiee.dev` | Public | CI/CD 테스트 앱 (setup-app 자동 생성) |
| [Homepage](https://github.com/gethomepage/homepage) | `home.ukkiee.dev` | Tailscale | Service dashboard |
| [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome) | `adguard.ukkiee.dev` | Tailscale | DNS ad blocker |
| [Uptime Kuma](https://github.com/louislam/uptime-kuma) | `status.ukkiee.dev` | Tailscale | Uptime monitoring |
| PostgreSQL | - | Cluster internal | Shared Postgres (Bitnami Helm) |

### Infrastructure

| Service | Domain | Description |
|---------|--------|-------------|
| ArgoCD | `argo.ukkiee.dev` | GitOps deployment engine |
| Traefik | `traefik.ukkiee.dev` | Reverse proxy + TLS termination |
| Cloudflared | - | Cloudflare Tunnel for public access |
| Tailscale Operator | - | VPN mesh for internal access |
| Sealed Secrets | - | K8s secret encryption at rest |
| ARC Runners | - | Self-hosted GitHub Actions (0-3 runners) |

### Monitoring

| Service | Domain | Description |
|---------|--------|-------------|
| VictoriaMetrics | - | Prometheus-compatible TSDB |
| VictoriaLogs | - | Log aggregation |
| Grafana | `grafana.ukkiee.dev` | Dashboards + visualization |
| Alloy | - | Log/metric collection agent |
| Kube-State-Metrics | - | Kubernetes object metrics |
| Node-Exporter | - | Host-level metrics |

## Networking

**Public** (Cloudflare Tunnel): `test-web.ukkiee.dev` (및 setup-app으로 추가되는 public 앱)

**Public** (TLS only): `grafana.ukkiee.dev`

**Internal** (Tailscale-only): `home`, `dns`, `status`, `argo`, `traefik` (all `*.ukkiee.dev`)

**Security**:
- Cloudflare WAF: 5 custom rules (verified bot allow, geo challenge, threat score, malicious UA block, sensitive path block)
- Cloudflare Rate Limiting: login/auth path IP-based rate limit
- Security response headers: X-Content-Type-Options, X-Frame-Options, Referrer-Policy, Permissions-Policy
- HSTS enabled (max-age 6 months, includeSubDomains)
- Bot protection: AI bot blocking, AI Labyrinth
- Default-deny NetworkPolicy in apps namespace
- Traefik middlewares: security headers, rate limiting (50 req/min), gzip
- Tailscale IP allowlist (`100.64.0.0/10`)
- TLS via Let's Encrypt + Cloudflare DNS challenge (Full Strict mode)

## Automation

### App Lifecycle (GitHub Actions)

앱의 생성부터 제거까지 자동화되어 있다.

**온보딩** (`setup-app` composite action):
1. `apps.json`에 앱 등록
2. Terraform으로 Cloudflare DNS CNAME 생성
3. Tunnel API로 ingress rule 추가
4. K8s 매니페스트 + ArgoCD Application YAML 자동 생성
5. Git push → ArgoCD 자동 sync

**제거** (`teardown.yml` workflow):
1. `apps.json`에서 앱 삭제 + Terraform destroy
2. Tunnel ingress 제거 (Cloudflare API)
3. GHCR 패키지 삭제
4. 매니페스트 + ArgoCD Application 삭제
5. ArgoCD Application kubectl delete (finalizer cascade)

**감사** (`audit-orphans.yml` — 매주 월요일 09:00 KST):
- 고아 앱 탐지 (apps.json에는 있지만 GitHub 레포 없는 앱)
- Tunnel drift 탐지 (DNS vs Tunnel 불일치)
- Telegram 알림

### Image Update (`_update-image.yml`)

외부 앱 레포의 CI에서 호출하는 reusable workflow.
매니페스트의 이미지 태그를 갱신하고 git push (3회 retry).

## Backup Strategy

| Data | Method | Schedule | Retention |
|------|--------|----------|-----------|
| PostgreSQL (shared) | CronJob `pg_dump` → PVC `postgresql-backups` | Daily 03:00 KST | 7 days |
| PVC data (AdGuard, Uptime Kuma, Traefik ACME) | `backup.sh` | Manual | Last 7 backups |

**External backup 필수 항목** (클러스터 외부 보관):
- SealedSecrets key pair
- Secret values (CF API Token, Tunnel Token, OAuth keys)
- PVC backup archives

## Quick Start

```bash
# CLI 도구 설치
./scripts/setup.sh tools

# 클러스터 상태 확인
./scripts/setup.sh verify

# ArgoCD 배포 (모든 서비스 자동 sync)
kubectl apply -f argocd/root.yaml
```

## Makefile Commands

```bash
# 도움말
make help              # 전체 명령어 목록

# 상태 확인
make pods              # 전체 Pod 상태
make top               # 리소스 사용량 (CPU 기준 상위 20)
make health            # ArgoCD 앱 상태 + 비정상 Pod
make pvc               # PVC 스토리지 현황
make events            # 최근 K8s 이벤트 (30개)

# ArgoCD
make sync              # 전체 앱 동기화
make status            # ArgoCD 앱 목록 + sync 상태
make port-forward      # ArgoCD UI (localhost:8080)
make argocd-password   # 초기 admin 비밀번호

# 운영
make logs POD=<name> NS=<ns>              # Pod 로그
make restart NAME=deploy/<name> NS=<ns>   # Rolling restart
make backup                                # PVC 백업 실행
make seal-secret NS=<ns> NAME=<n> KEY=<v> # SealedSecret 생성
```

## Disaster Recovery

5가지 시나리오별 복구 절차가 [`docs/disaster-recovery.md`](docs/disaster-recovery.md)에 문서화되어 있다.

| Scenario | Recovery Time |
|----------|--------------|
| Pod/Service 장애 | 1-5분 |
| OrbStack/K3s 재시작 | 2-5분 |
| PVC 데이터 손상 | 15-30분 |
| macOS 재설치 | 1-2시간 |
| 하드웨어 교체 | 2-4시간 |
