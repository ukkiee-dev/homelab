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
```

## Tech Stack

| Category | Tool |
|----------|------|
| Platform | Mac Mini M4 + OrbStack K3s |
| GitOps | ArgoCD (self-heal, auto-sync) |
| Ingress | Traefik v3 + Cloudflare DNS ACME |
| Tunnel | Cloudflared (public), Tailscale (internal) |
| Secrets | Sealed Secrets (Bitnami) |
| Monitoring | VictoriaMetrics + VictoriaLogs + Grafana + Alloy |
| CI/CD | ARC (Actions Runner Controller) |
| Image Update | ArgoCD Image Updater |
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
│   │   └── network-policies/    # Namespace NetworkPolicy rules
│   ├── apps/
│   │   ├── immich/              # Photo library (server, ML, postgres, redis)
│   │   ├── homepage/            # Service dashboard
│   │   ├── adguard/             # DNS ad blocker
│   │   ├── uptime-kuma/         # Uptime monitoring
│   │   ├── api-server/          # Custom API backend
│   │   └── postgresql/          # Shared PostgreSQL + backup CronJob
│   └── monitoring/
│       ├── victoria-metrics/    # Metrics TSDB (30d retention)
│       ├── victoria-logs/       # Log store (15d retention)
│       ├── grafana/             # Dashboards + alerting
│       └── alloy/               # Log/metric collector (DaemonSet)
├── docs/
│   └── disaster-recovery.md     # DR playbook (6 scenarios)
├── scripts/
│   └── setup.sh                 # CLI tool installer + context setup
├── Makefile                     # Operational commands
├── backup.sh                    # PVC backup script
└── renovate.json                # Dependency update config
```

## Services

### Applications

| Service | Domain | Access | Description |
|---------|--------|--------|-------------|
| [Immich](https://github.com/immich-app/immich) | `photos.ukkiee.dev` | Public | Self-hosted photo/video library |
| [Homepage](https://github.com/gethomepage/homepage) | `home.ukkiee.dev` | Tailscale | Service dashboard |
| [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome) | `dns.ukkiee.dev` | Tailscale | DNS ad blocker |
| [Uptime Kuma](https://github.com/louislam/uptime-kuma) | `status.ukkiee.dev` | Tailscale | Uptime monitoring |
| API Server | `api.ukkiee.dev` | Tailscale | Custom API backend |

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

## Networking

**Public** (Cloudflare Tunnel): `photos.ukkiee.dev`

**Public** (TLS only): `grafana.ukkiee.dev`

**Internal** (Tailscale-only): `home`, `api`, `dns`, `status`, `argo`, `traefik` (all `*.ukkiee.dev`)

**Security**:
- Default-deny NetworkPolicy in apps namespace
- Traefik middlewares: security headers, rate limiting (50 req/min), gzip
- Tailscale IP allowlist (`100.64.0.0/10`)
- TLS via Let's Encrypt + Cloudflare DNS challenge

## Backup Strategy

| Data | Method | Schedule | Retention |
|------|--------|----------|-----------|
| Immich DB | CronJob `pg_dump` → external SSD + Restic → R2 | Daily 03:00 KST | 7d / 4w / 6m |
| Immich media | External SSD + Restic → R2 | Daily 03:00 KST | 7d / 4w / 6m |
| PostgreSQL (shared) | CronJob `pg_dump` | Daily 03:00 KST | 7 days |
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
make apply
```

## Makefile Commands

```bash
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

6가지 시나리오별 복구 절차가 [`docs/disaster-recovery.md`](docs/disaster-recovery.md)에 문서화되어 있다.

| Scenario | Recovery Time |
|----------|--------------|
| Pod/Service 장애 | 1-5분 |
| OrbStack/K3s 재시작 | 2-5분 |
| PVC 데이터 손상 | 15-30분 |
| macOS 재설치 | 1-2시간 |
| 하드웨어 교체 | 2-4시간 |
| 외장 SSD 장애 | 수시간-수일 |
