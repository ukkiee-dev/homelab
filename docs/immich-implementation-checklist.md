# Immich 구현 체크리스트

> 시작일: 2026-03-26
> 플랜 문서: `docs/immich-backup-analysis.md`

---

## Phase S-1: 하드웨어 준비 ✅

- [x] NVMe 인클로저 연결 (TBU405, TB4 40Gb/s, 후면 포트 2)
- [x] SK hynix Gold P31 2TB APFS 포맷 (볼륨명: `ukkiee`)
- [x] 디렉토리 구조 생성 (`immich/`, `backups/pgdump/`, `backups/restic/`)
- [x] SMART Verified, TRIM Yes 확인

## Phase S-2: macOS 설정 ✅

- [x] pmset (disksleep=0, sleep=0, displaysleep=0)
- [x] Full Disk Access (Ghostty + OrbStack)
- [x] diskutil enableOwnership
- [x] Spotlight 비활성화 (`mdutil -i off`)
- [x] Time Machine 제외 (`tmutil addexclusion`)
- [x] smartmontools 설치

## Phase S-3: OrbStack 경로 검증 ✅

- [x] 노드명 확인: `orbstack`
- [x] Docker bind mount R/W 테스트 PASS
- [x] K8s hostPath bind mount R/W 테스트 PASS (2.8 GB/s)

## Phase S-4: K8s 리소스 배포 ✅

- [x] `immich` namespace 생성
- [x] DB Secret 생성 (비밀번호 매니저에 저장 필요)
- [x] PV 4개 + PVC 4개 Bound (media, backup, postgres, ml-cache)
- [x] PostgreSQL 배포 → `pg_isready` PASS
- [x] Redis 배포 → `redis-cli ping` PONG
- [x] Immich Server 배포 → `/api/server/ping` PASS
- [x] Immich ML 배포 → `/ping` PASS
- [x] IngressRoute 배포 (web + websecure, tailscale-only)
- [x] Cloudflare Tunnel Public Hostname 추가
- [x] DNS 캐시 클리어 (AdGuard + macOS)
- [x] 웹 UI 접속 확인 (`photos.ukkiee.dev`)
- [x] Admin 계정 생성
- [x] 사진 업로드 + 썸네일 + ML 처리 확인

### 트러블슈팅 기록

| 문제 | 원인 | 해결 |
|------|------|------|
| 외장 SSD Permission Denied | macOS TCC — Full Disk Access 미부여 | Ghostty + OrbStack FDA 추가 + enableOwnership |
| photos.ukkiee.dev 접속 불가 | AdGuard NXDOMAIN 캐시 | AdGuard 캐시 클리어 |
| IngressRoute 404 | Tunnel은 HTTP:80, IngressRoute는 websecure만 | entryPoints에 `web` 추가 |

---

## Phase S-4f: NetworkPolicy ✅

- [x] `immich` namespace default deny (ingress + egress, DNS만 허용)
- [x] Immich Server → PostgreSQL (egress, port 5432)
- [x] Immich Server → Redis (egress, port 6379)
- [x] Immich Server → Immich ML (egress, port 3003)
- [x] Immich Server/ML → DNS (egress, port 53) — default deny에 포함
- [x] Immich ML → internet:443 (egress) — 모델 다운로드
- [x] PostgreSQL ← namespace 내 모든 Pod (ingress, port 5432)
- [x] Redis ← Server (ingress, port 6379)
- [x] ML ← Server (ingress, port 3003)
- [x] Traefik → Immich Server (ingress, port 2283)
- [x] 검증: server ping OK, server→ml OK, postgres OK, 외부 접속 OK

## Phase S-5: 백업 자동화 ✅

- [x] R2 버킷 생성 (`immich-backup-ukkiee`, Standard class)
- [x] R2 S3 호환 API Token 생성 (Object Read & Write)
- [x] K8s Secret 생성 (`immich-restic` — R2 키 + Restic 비밀번호)
- [x] Restic R2 repo 초기화 완료
- [x] Restic 로컬 repo 초기화 완료 (`/backups/restic/`)
- [x] CronJob 매니페스트 작성 (initContainer: pg_dump → main: restic)
- [x] CronJob 배포 (매일 03:00 KST = UTC 18:00)
- [x] 수동 백업 실행 → pg_dump + 로컬 Restic + R2 Restic 모두 성공
- [x] 수동 복원 테스트 → R2에서 pgdump + 사진 복원 PASS
- [x] `backup.sh` 업데이트 — Immich 상태 확인 섹션 추가, 실행 검증 완료

### 비밀번호 매니저 저장 ✅

- [x] Bitwarden `Homelab` 폴더에 3개 항목 저장
  - Immich PostgreSQL (DB 접속 정보)
  - Immich Restic Backup (Restic 비밀번호 + repo 경로)
  - Cloudflare R2 - Immich Backup (API 키 + endpoint)

## Phase S-6: 모니터링 ✅

- [x] launchd 워치독 스크립트 작성 (`~/Scripts/check-immich-ssd.sh`)
- [x] launchd plist 작성 + 등록 (`~/Library/LaunchAgents/dev.homelab.check-ssd.plist`)
- [x] 푸시 알림 수신 확인 (Moshi 앱)
- [ ] (Phase 1 이후) AlertManager 규칙 추가
- [x] ~~모바일 앱 자동 백업~~ — 사용 안 함

## Git 커밋 ✅

- [x] GitHub repo 생성 (`ukkiee-dev/homelab`, private)
- [x] 9개 그룹별 커밋 (scaffolding → infra → apps → immich → monitoring → docs)
- [x] Push to origin/main

---

## 생성/수정된 파일 목록

| 파일 | 용도 |
|------|------|
| `k8s/base/immich/namespace.yaml` | immich namespace |
| `k8s/base/immich/pv.yaml` | PV 4개 (media, backup, postgres, ml-cache) |
| `k8s/base/immich/pvc.yaml` | PVC 4개 |
| `k8s/base/immich/postgres.yaml` | PostgreSQL Deployment + Service |
| `k8s/base/immich/redis.yaml` | Redis Deployment + Service |
| `k8s/base/immich/server.yaml` | Immich Server Deployment + Service |
| `k8s/base/immich/ml.yaml` | Immich ML Deployment + Service |
| `k8s/base/immich/ingressroute.yaml` | Traefik IngressRoute |
| `k8s/base/immich/network-policy.yaml` | NetworkPolicy 7개 |
| `k8s/base/immich/backup-cronjob.yaml` | 백업 CronJob (pg_dump + Restic) |
| `k8s/base/immich/kustomization.yaml` | Kustomize 설정 |
| `argocd/applications/immich.yaml` | ArgoCD Application |
| `k8s/overlays/production/kustomization.yaml` | immich 리소스 추가 (수정) |
| `~/Scripts/check-immich-ssd.sh` | SSD 워치독 스크립트 |
| `~/Library/LaunchAgents/dev.homelab.check-ssd.plist` | launchd plist |
| `docs/immich-backup-analysis.md` | 플랜 문서 (수정) |
| `docs/immich-implementation-checklist.md` | 이 체크리스트 |
| `docs/implementation-plan.md` | Phase S 추가 (수정) |
| `docs/disaster-recovery.md` | Immich 복구 시나리오 추가 (수정) |
