# Phase 2 구현 체크리스트 — GHCR + CI/CD

> 시작일: 2026-03-26
> API 서버 repo: `ukkiee-dev/api-server`

---

## Phase 2-A: GitHub Actions Workflow ✅

- [x] `.github/workflows/build.yaml` 작성 (api-server repo)
- [x] GHCR 빌드 + push (태그: latest + sha, ARM64)
- [x] Trivy 취약점 스캔 (filesystem 모드 — ARM64 이미지 스캔 불가 우회)
- [x] Push → 빌드 성공 → `ghcr.io/ukkiee-dev/api-server:latest` 확인

## Phase 2-B: K8s 배포 + imagePullSecret ✅

- [x] GHCR imagePullSecret 생성 (`ghcr-pull-secret`, apps namespace)
- [x] API 서버 매니페스트 (Deployment + Service + IngressRoute)
- [x] ArgoCD Application 생성
- [x] 배포 + `/health/ping` 정상 확인

## Phase 2-C: ArgoCD Image Updater ✅

- [x] Image Updater Helm 배포 (v1.1.1, CRD 기반)
- [x] ImageUpdater CR 생성 (api-server, digest strategy)
- [x] ArgoCD repo credentials 추가 (homelab + api-server)
- [x] ArgoCD Application sync 성공 (sourceType: Kustomize)
- [x] Image Updater → GHCR 이미지 감지 → ArgoCD spec 자동 업데이트 확인
