# K8s 메모리 최적화 — 전체 완료

> 최종 업데이트: 2026-04-02
> **Phase 0~4 전체 완료** — 남은 작업 없음

---

## 완료 항목

| 항목 | 완료일 |
|------|--------|
| Phase 0: ArgoCD 드리프트 해소 + cadvisor scrape config | 2026-04-01 |
| Phase 0: Reloader/PostgreSQL values Git 추적 | 2026-04-01 |
| Phase 0: appset-controller 잔존 deploy 삭제 | 2026-04-01 |
| Phase 1: 6개 워크로드 request 상향 | 2026-04-01 |
| Phase 1: tailscale operator + ProxyClass BestEffort 해소 | 2026-04-01 |
| Phase 1: CronJob 리소스 추가 | 2026-04-01 |
| Phase 1: Reloader helm upgrade (경로 수정) | 2026-04-01 |
| Phase 2: 10개 워크로드 req/lim 하향 (Git) | 2026-04-01 |
| Phase 2: Traefik req/lim 하향 + Recreate | 2026-04-01 |
| Phase 2: ArgoCD helm upgrade (revision 11) | 2026-04-01 |
| Phase 2: image-updater req/lim 64/128→32/48Mi | 2026-04-01 |
| Phase 2: PostgreSQL helm upgrade (24h 피크 46.2Mi 확인, req/lim 48/96Mi) | 2026-04-02 |
| Phase 3: PriorityClass 4개 적용 | 2026-04-01 |
| Phase 3: LimitRange 8개 NS 적용 | 2026-04-01 |
| Phase 3: 전체 워크로드 priorityClassName 추가 | 2026-04-01 |
| Phase 3: ResourceQuota 8개 NS 재활성화 | 2026-04-01 |
| Phase 4: kubelet eviction threshold (OrbStack Settings UI) | 2026-04-02 |

## Phase 4 설정 내역

OrbStack Settings > Kubernetes > "Kubelet Configuration"에 적용:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
evictionHard:
  memory.available: "100Mi"
  nodefs.available: "5%"
  imagefs.available: "5%"
evictionSoft:
  memory.available: "200Mi"
  nodefs.available: "10%"
evictionSoftGracePeriod:
  memory.available: "30s"
  nodefs.available: "1m"
evictionPressureTransitionPeriod: "30s"
```

## 적용 과정에서 발견된 이슈

- **Helm v4 field manager 충돌**: `configs.cm.accounts.ukkiee`를 values에서 제거, argocd-server 위임
- **deploymentStrategy Recreate 제한**: ArgoCD chart가 rollingUpdate 파라미터와 충돌. values에서 제거
- **ResourceQuota 적용 순서**: 기존 limit 초과로 파드 생성 차단 → helm upgrade 완료 후 재활성화
- **OrbStack kubelet config**: v2.0.1+에서 Settings UI 지원. plist 직접 수정은 불가(앱이 인식하지 않음), GUI 필수
