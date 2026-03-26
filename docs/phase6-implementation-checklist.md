# Phase 6 구현 체크리스트 — 공개 서비스 보안

> 시작일: 2026-03-27
> 공개 서비스: photos.ukkiee.dev (Immich), home.ukkiee.dev, api.ukkiee.dev

---

## Phase 6-A: External DNS ⬜ (후순위)

- [ ] External DNS Helm 배포
- [ ] Cloudflare DNS 자동 관리 테스트

## Phase 6-B: Cloudflare 보안 ⬜

- [ ] WAF Managed Rules 활성화 (OWASP)
- [ ] Bot Fight Mode 활성화
- [ ] Rate Limiting Rule 설정
- [ ] Traefik Rate Limit Middleware 추가

## Phase 6-C: CrowdSec + Traefik Bouncer ⬜

- [ ] CrowdSec Helm 배포 (Agent + LAPI)
- [ ] Traefik 액세스 로그 활성화
- [ ] Traefik Bouncer Plugin 설정
- [ ] CrowdSec CAPI 등록
- [ ] NetworkPolicy
- [ ] 공개 IngressRoute에 bouncer middleware 추가

## Phase 6-D: Cloudflare Bouncer (선택) ⬜

- [ ] CrowdSec → Cloudflare 엣지 차단
