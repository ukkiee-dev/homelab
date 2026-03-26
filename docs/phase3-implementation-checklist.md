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

## Phase 3-B: PostgreSQL (API 서버용) ⬜

- [ ] PostgreSQL 배포 (Bitnami Helm)
- [ ] API 서버용 database 생성
- [ ] Infisical용 database 사전 생성 (Phase 4 대비)

## Phase 3-C: PostgreSQL 백업 자동화 ⬜

- [ ] pgdump CronJob 배포
- [ ] 복원 테스트
- [ ] backup.sh 업데이트
