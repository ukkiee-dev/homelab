# Phase 3 구현 체크리스트 — Argo Rollouts + PostgreSQL

> 시작일: 2026-03-26

---

## Phase 3-A: Argo Rollouts ✅

- [x] Argo Rollouts Helm 설치
- [x] api-server Deployment → Rollout 전환 (blue/green)
- [x] activeService + previewService 구성
- [x] autoPromotionEnabled: false (수동 승인)
- [x] Blue/Green 테스트: active=v2, preview=v3 확인
- [x] Promote → active=v3 전환 확인

## Phase 3-B: PostgreSQL ✅

- [x] PostgreSQL 배포 (Bitnami Helm, apps namespace)
- [x] `api` database 생성 (API 서버용)
- [x] `infisical` database 사전 생성 (Phase 4 대비, initdb script)
- [x] 접속 확인
- [x] PG_PASS Bitwarden 저장 필요

## Phase 3-C: PostgreSQL 백업 자동화 ✅

- [x] pgdump CronJob 배포 (매일 03:00 KST)
- [x] PVC 1Gi (backups 저장)
- [x] 수동 백업 테스트 → api + infisical 덤프 성공
