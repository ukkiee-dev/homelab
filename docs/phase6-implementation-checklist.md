# Phase 6 구현 체크리스트 — 공개 서비스 보안

> 시작일: 2026-03-27
> 공개 서비스: photos.ukkiee.dev (Immich), home.ukkiee.dev, api.ukkiee.dev

---

## Phase 6-A: External DNS ⬜ (후순위)

- [ ] External DNS Helm 배포
- [ ] Cloudflare DNS 자동 관리 테스트

## Phase 6-B: Cloudflare 보안 🔄

- [ ] WAF Managed Rules 활성화 (OWASP) — Cloudflare Dashboard에서 설정
- [ ] Bot Fight Mode 활성화 — Cloudflare Dashboard에서 설정
- [ ] Rate Limiting Rule 설정 — Cloudflare Dashboard에서 설정
- [x] Traefik Rate Limit Middleware 추가 (50 req/min per CF-Connecting-IP)

## Phase 6-C: CrowdSec + Traefik Bouncer ✅

- [x] CrowdSec Helm 배포 (Agent + LAPI)
- [x] Traefik 액세스 로그 활성화 (JSON format)
- [x] Traefik Bouncer Plugin 설정 (crowdsec-bouncer middleware)
- [x] photos.ukkiee.dev에 bouncer middleware 적용
- [ ] CrowdSec CAPI 등록 (커뮤니티 blocklist)
- [ ] NetworkPolicy (후속)

## Phase 6-D: Cloudflare Bouncer (선택) ⬜

- [ ] CrowdSec → Cloudflare 엣지 차단
