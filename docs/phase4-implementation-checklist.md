# Phase 4 구현 체크리스트 — Infisical 시크릿 관리

> 시작일: 2026-03-26
> 선행: Phase 3-B PostgreSQL (api + infisical DB 완료)

---

## Phase 4-A: Infisical 인프라 배포 ✅

- [x] `infisical` namespace 생성
- [x] Redis 배포 (Infisical 전용, Bitnami standalone)
- [x] ENCRYPTION_KEY + AUTH_SECRET 생성 (Bitwarden 저장 필요)
- [x] Infisical Helm 배포 (infisical-standalone, readiness probe 조정)
- [x] IngressRoute (`secrets.ukkiee.dev`, Tailscale IP DNS only)
- [x] 웹 UI 접속 + admin 계정 생성

## Phase 4-B: Reloader ✅

- [x] Stakater Reloader Helm 배포 (kube-system)

## Phase 4-C: Infisical Operator ✅

- [x] Infisical Secrets Operator Helm 배포
- [x] Machine Identity 생성 (`k8s-operator`, Universal Auth)
- [x] Machine Identity Secret 배포 (apps, immich, monitoring)

## Phase 4-D: 시크릿 마이그레이션 ✅

- [x] Infisical 프로젝트 `homelab` 생성 (prod 환경)
- [x] 10개 시크릿 Infisical에 등록
  - IMMICH_DB_PASSWORD, RESTIC_PASSWORD
  - R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT
  - POSTGRESQL_PASSWORD, GRAFANA_ADMIN_PASSWORD, TELEGRAM_BOT_TOKEN
  - INFISICAL_ENCRYPTION_KEY, INFISICAL_AUTH_SECRET
- [x] InfisicalSecret CRD 배포 (apps, immich, monitoring)
- [x] 3개 namespace에서 10개 시크릿 자동 동기화 확인 (60초 간격)

## Phase 4-E: SealedSecrets 제거 ⬜

- [ ] InfisicalSecret CRD 동기화 검증 후 제거
