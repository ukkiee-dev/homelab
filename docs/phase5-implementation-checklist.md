# Phase 5 구현 체크리스트 — Analysis Template (자동 롤백)

> 시작일: 2026-03-27

---

## Phase 5: Analysis Template ⬜

- [ ] AnalysisTemplate 리소스 작성 (Pod readiness 기반)
- [ ] Rollout에 prePromotionAnalysis 연결
- [ ] 정상 이미지 → 자동 promote 테스트
- [ ] 에러 이미지 → 자동 rollback 테스트
- [ ] autoPromotionEnabled: true 전환
- [ ] (1주일 후) HTTP 메트릭 기반 threshold 튜닝
