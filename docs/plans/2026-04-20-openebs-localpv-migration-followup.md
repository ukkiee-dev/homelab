# OpenEBS LocalPV Hostpath 전환 — 잔여 TODO

> **작성일**: 2026-04-20
> **상태**: **잔여 TODO · CNPG 마이그레이션 완료 직후 실행 예정 (확정)**
> **선행 작업**: [2026-04-20-cloudnativepg-migration-plan.md](2026-04-20-cloudnativepg-migration-plan.md) Phase 0–9 완료
> **다음 문서**: 실행 시점에 `docs/plans/YYYY-MM-DD-openebs-localpv-migration-plan.md` 별도 생성

---

## 0. TL;DR

**결정**: K3s 번들 `local-path-provisioner v0.0.31` 은 PVC resize 미지원 (Issue #190 OPEN, 2026-04-20 pre-verified). CNPG PVC 뿐 아니라 VictoriaMetrics·Logs·Grafana 등 **모든 stateful workload** 에 동일 한계. **CNPG 마이그레이션 완료 후 즉시 OpenEBS LocalPV Hostpath 로 StorageClass 전환** 이니셔티브 진행한다.

본 문서는 그 시점에 재작성할 실행 계획의 **골격·의사결정·범위** 를 미리 박제해 둔 것. CNPG 완료 시점에 이 문서를 기반으로 실제 plan 을 Phase-level detail 까지 쪼개 작성.

---

## 1. 배경

### 1.1 현재 StorageClass 현황

홈랩은 K3s 기본 `local-path` storage class 하나만 사용 중. Rancher local-path-provisioner 가 `/var/lib/rancher/k3s/storage/...` 경로에 호스트 디렉토리를 PV로 프로비저닝.

**한계**:
- 2024-이전 버전은 `allowVolumeExpansion: false` — kubectl patch로 용량 증설 불가
- snapshot 미지원
- PVC 레벨 QoS 제어 불가

### 1.2 영향받는 stateful workload

현재 PVC 사용 리소스 목록 (확인된 것들):

| 리소스 | PVC | 현재 용량 | resize 필요성 |
|---|---|---|---|
| Bitnami PostgreSQL (폐기 예정) | `data-postgresql-0` | 5Gi | N/A (Phase 8에서 제거) |
| PostgreSQL backup storage | `postgresql-backups` | 미확인 | N/A |
| VictoriaMetrics | `storage-victoria-metrics-0` | 미확인 | 중 (30d retention 성장) |
| VictoriaLogs | `storage-victoria-logs-0` | 미확인 | 중 (15d retention) |
| AdGuard Home | `adguard-data` | 미확인 | 낮음 |
| Uptime Kuma | `uptime-kuma-data` | 미확인 | 낮음 |
| Traefik ACME | `traefik-data` | 미확인 | 낮음 (certs 파일 < 100KB) |
| Grafana | `grafana-storage` | 미확인 | 낮음 |
| **CNPG Clusters** (신설) | `<project>-pg-*` | 3Gi/5Gi default | **중–높음** (DB 성장) |

정확한 현재 용량·사용량은 실행 시점에 재조사.

---

## 2. 왜 OpenEBS LocalPV Hostpath 인가

### 2.1 옵션 비교

| 옵션 | Resize | Snapshot | 오버헤드 | 단일 노드 적합 |
|---|---|---|---|---|
| K3s local-path (현재) | ❌ (버전 의존) | ❌ | 0 | ✓ |
| **OpenEBS LocalPV Hostpath** | ✓ | ✓ (v3.5+) | ~50Mi operator | ✓ |
| Longhorn | ✓ | ✓ | ~500Mi+ | △ (multi-node 전제) |
| Rook Ceph | ✓ | ✓ | ~1Gi+ | ✗ (multi-node 필수) |
| OpenEBS Mayastor | ✓ | ✓ | ~500Mi+ | △ |

**OpenEBS LocalPV Hostpath 선택 근거**:
- local-path 와 동일한 host directory 방식 → 마이그레이션 경로 단순 (경로 수준 1:1 복사 가능)
- CSI driver 제공 → resize·snapshot 표준 K8s API 동작
- 홈랩 규모에 적합 (Longhorn/Ceph 같은 distributed storage 오버헤드 없음)
- 단일 노드 K3s 환경에서 검증된 사용 사례 다수

### 2.2 CNPG 후로 순연하는 이유 (병행 실행 하지 않는 이유)

- CNPG 마이그레이션 자체 의존성(cert-manager + CNPG operator + plugin) 이 3개 layer → 동시에 storage layer 까지 건드리면 장애 시 원인 분리 불가
- CNPG Phase 6 에서 첫 실제 프로젝트 DB 올린 **직후** 가 OpenEBS 시작의 자연스러운 지점 (CNPG 가 첫 resize pain point 가 될 stateful workload)
- 기존 workload (VM·Logs·AdGuard 등) 마이그레이션은 각 workload 별 backup·restore 절차가 필요 → CNPG 일정 중에 섞으면 인지 부담 과다

**순서**: CNPG Phase 0–9 완료 → 본 문서 기반 실제 plan 작성 → OpenEBS Phase OEBS-0–6 순차 실행.

---

## 3. 실행 시점 & 사전 조건

### 3.1 실행 시점 (확정)

**CNPG 마이그레이션 Phase 9 완료 직후**. 별도 trigger 조건 체크 불필요 — 이미 실행 확정.

### 3.2 사전 조건 (CNPG 완료 정의)

본 이니셔티브 Phase OEBS-0 시작 전 아래가 모두 ✅:
- [ ] CNPG `.../cloudnativepg-migration-plan.md` Phase 0–9 완료
- [ ] CNPG 관련 최소 1개 실제 프로젝트가 30일 이상 운영되어 실 PVC 사용 패턴 파악됨
- [ ] Bitnami 폐기 완료 (Phase 8)
- [ ] Runbook 4종 작성 완료 (Phase 9)

### 3.3 재평가 trigger (확정 취소할 이유가 있을 때만)

아래 중 하나 발생 시 "OpenEBS 이니셔티브 재평가":

- **R1**: `rancher/local-path-provisioner` 에서 volume expansion 정식 지원 릴리스 (Issue #190 CLOSED-COMPLETED). 이 경우 OpenEBS 전환 불필요, 본 문서 아카이브.
- **R2**: K3s upstream 이 local-path 대신 다른 default provisioner 로 전환 → upstream 따라가기
- **R3**: 단일 노드 → multi-node 확장 계획 구체화 → Longhorn 재평가

감시 방법:
- R1: `gh issue view 190 --repo rancher/local-path-provisioner` 월 1회 상태 체크 (Renovate 로 자동화 고려)
- R2: K3s release notes 구독
- R3: 별도 이슈

---

## 4. 범위

### 4.1 범위 안

- OpenEBS LocalPV Hostpath operator 설치
- StorageClass 추가 (`openebs-hostpath`) — default 전환은 별도 단계
- 기존 `local-path` PVC 를 하나씩 `openebs-hostpath` 로 마이그레이션
- 마이그레이션 완료 후 default StorageClass 전환
- local-path-provisioner 폐기 (모든 PVC 이관 완료 시점에)

### 4.2 범위 밖

- Longhorn / Rook Ceph / Mayastor 평가 (T4 trigger 시 별도 문서)
- PV migration 자동화 툴 개발 (PV Migrator 등) — 수동 stop/backup/restore 방식
- 스토리지 암호화 (등장하면 별도 이슈로)

---

## 5. 마이그레이션 전략 옵션

### Option M-1: 병행 운영 + 점진 마이그레이션 ⭐ 권장

1. OpenEBS 설치 + `openebs-hostpath` StorageClass 추가 (default 아님)
2. 기존 `local-path` 는 그대로 유지
3. **신규 PVC 부터** `storageClassName: openebs-hostpath` 명시적 사용
4. 기존 PVC 는 workload 별로 하나씩:
   - Stop workload
   - Backup 데이터 (R2 또는 외장 SSD)
   - 새 PVC 생성 (openebs-hostpath)
   - Restore
   - workload 재시작
5. 모든 PVC 이관 완료 → default StorageClass 를 `openebs-hostpath` 로 전환
6. local-path-provisioner deployment 제거

**장점**: 각 workload 개별 rollback 가능, 사고 blast radius 제한
**단점**: 전환 기간 2개 StorageClass 공존으로 인한 인지 부담

### Option M-2: 빅뱅 전환

전 holdout 을 하루 downtime 으로 일괄 전환. 홈랩 scale 에서 비추.

### Option M-3: volume clone (지원되면)

OpenEBS LocalPV Hostpath 에 source PV 지정 clone 기능이 있다면 stop 없이 복사 가능. 확인 필요.

---

## 6. Phase-level 계획 (M-1 기준)

> 각 Phase 는 CNPG Phase 0-9 와 유사한 detail 로 후속 확정.

### Phase OEBS-0: 조사·결정 (1일)
- OpenEBS 최신 버전 · LocalPV Hostpath chart pin
- 현재 각 PVC 실제 사용량 측정 (`kubectl exec` + `du -sh`)
- 이관 대상 workload 별 다운타임 허용 범위 결정
- backup 저장소 결정 (R2 vs 외장 SSD)

### Phase OEBS-1: OpenEBS 설치 (1일)
- `manifests/infra/openebs/` 구성 (Helm)
- ArgoCD Application 추가 (syncWave 도 -3 수준, cert-manager 근처)
- `openebs-hostpath` StorageClass 생성 (non-default)
- operator pod health 확인

### Phase OEBS-2: 신규 PVC만 openebs-hostpath 사용 (0.5일)
- CNPG `Cluster.spec.storage.storageClass` 를 `openebs-hostpath` 로 변경
- 신규 프로젝트 부터 기본값 전환 (setup-app template 수정)

### Phase OEBS-3: 기존 workload 마이그레이션 (3-5일, workload 당 0.5-1일)

워크로드 순서 (영향 낮은 순):
1. Traefik ACME (데이터 수 MB, 장애 시 acme 자동 재발급)
2. Uptime Kuma (restart 자동)
3. AdGuard (DNS 캐시 손실 허용)
4. Grafana (dashboard/alert rule 재로딩)
5. CNPG Clusters (PITR 으로 복구)
6. VictoriaLogs (15d retention 손실 각오, 또는 snapshot 후 import)
7. VictoriaMetrics (30d retention 손실 각오, 또는 snapshot 후 import)

각 workload 마이그레이션 패턴:
```bash
# 1. Scale down
kubectl -n <ns> scale deploy/<app> --replicas=0

# 2. Backup (방식은 workload 별 · R2 또는 local tarball)
kubectl -n <ns> exec <helper> -- tar czf /backup/<app>.tar.gz /data
kubectl cp <helper>:/backup/<app>.tar.gz ./backups/

# 3. 신규 PVC (openebs-hostpath) 생성
cat > new-pvc.yaml <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
...
spec:
  storageClassName: openebs-hostpath
  resources: { requests: { storage: <old-size>Gi } }
EOF
kubectl apply -f new-pvc.yaml

# 4. Restore
# ... helper pod 에서 tar 로 복원 ...

# 5. workload manifest 의 PVC 참조를 신규로 변경 후 apply

# 6. Scale up + 검증

# 7. 기존 local-path PVC 삭제
```

CNPG Cluster 는 별도 절차 (backup + bootstrap.recovery 로 openebs-hostpath 에 신규 Cluster 생성).

### Phase OEBS-4: default StorageClass 전환 (0.5일)
- `openebs-hostpath` 를 default 로 설정
- `local-path` 를 default 에서 해제
- 모든 PVC 가 `openebs-hostpath` 사용 확인 (`kubectl get pvc -A | grep -v openebs`)

### Phase OEBS-5: local-path-provisioner 제거 (0.5일)
- PVC 0건 남은 것 재확인
- local-path-provisioner deployment 삭제
- 매니페스트 디렉토리 정리
- 관련 SealedSecret·ConfigMap 잔존 확인

### Phase OEBS-6: 문서화 (1일)
- Runbook: `docs/runbooks/storage/pvc-resize.md` — 새 절차 (kubectl patch 1줄)
- Runbook: `docs/runbooks/storage/openebs-troubleshooting.md`
- CNPG PITR runbook 업데이트 (snapshot 옵션 추가)
- 기존 disaster-recovery.md 업데이트

**예상 총 기간**: 6-8일

---

## 7. 리스크 & 완화

| 리스크 | 심각도 | 완화 |
|---|---|---|
| workload 데이터 손실 (backup 실패) | **높** | 모든 workload 별로 restore 시뮬레이션 선행 (dry-run) · 외장 SSD 이중 backup |
| OpenEBS operator 장애 → 새 PVC 프로비저닝 불가 | 중 | local-path 병행 유지 기간 확보 · fallback ready |
| Hostpath 경로 충돌 (로컬 FS 같은 위치) | 중 | basePath 명시적 분리 (`/var/lib/openebs-hostpath/` 등) |
| snapshot 기능 CSI 드라이버 상 비호환 | 낮 | 실전 테스트 후 사용 여부 결정 |
| 특정 workload 가 ReadWriteMany 필요 | 낮 | Hostpath 는 RWO only — 현재 홈랩에 RWM 없음 재확인 |

---

## 8. 롤백

Phase 별 rollback:
- **Phase OEBS-0~1**: OpenEBS Application 삭제 (PVC 없으므로 영향 0)
- **Phase OEBS-2~3**: 개별 workload 마이그레이션 실패 시 원본 PVC 복원 (삭제 전까지 유지)
- **Phase OEBS-4**: default StorageClass revert (kubectl annotate)
- **Phase OEBS-5**: 되돌리기 어려움 — Phase 4까지 검증 완료 필수

---

## 9. 성공 기준

- [ ] 모든 PVC가 `openebs-hostpath` storageClassName 사용
- [ ] 테스트 resize: `kubectl patch pvc` 1줄로 용량 증설 성공 (CNPG Cluster 기준)
- [ ] snapshot 기능 smoke test: 임시 snapshot → restore 가능
- [ ] local-path-provisioner deployment 제거 완료
- [ ] 각 workload 복구 시간 (migration 전후) 동일 또는 개선
- [ ] 30일 무장애 운영

---

## 10. 실행 판정 (단순 checklist)

이 문서는 "실행 확정" 상태. CNPG Phase 9 완료 시 아래 checklist 를 순회:

```
[x] D 시나리오 확정 (2026-04-20 pre-verified)
[ ] CNPG Phase 0–9 완료
[ ] CNPG 1개 이상 실 프로젝트 30일 안정 운영
[ ] 운영자 시간 6–8일 확보 가능
[ ] 각 stateful workload 다운타임 최대 1시간 허용 가능

모두 ✅ → 실제 plan 문서 작성 (docs/plans/YYYY-MM-DD-openebs-localpv-migration-plan.md) → Phase OEBS-0 착수
재평가 trigger (§3.3) 발생 → 이니셔티브 재평가 또는 취소
```

---

## 11. 열린 질문 (실행 시점에 답)

- Q-OEBS-1: OpenEBS Helm chart 최신 stable 버전 · 호환 K3s 버전
- Q-OEBS-2: `openebs-hostpath` basePath 를 어디에 둘지 (`/var/lib/openebs-hostpath`? 또는 `/Volumes/ukkiee/...` 외장 SSD?)
- Q-OEBS-3: VictoriaMetrics·Logs 의 retention 데이터 손실 허용 여부 (snapshot+restore 가치 평가)
- Q-OEBS-4: Snapshot scheduled 도입 여부 (Velero 같은 상위 백업 도구와 통합)

---

## 12. 참고 자료

- OpenEBS LocalPV Hostpath: https://openebs.io/docs/user-guides/localpv-hostpath
- CSI VolumeResize KEP: https://github.com/kubernetes/enhancements/tree/master/keps/sig-storage/1790-recover-resize-failure
- Rancher local-path-provisioner: https://github.com/rancher/local-path-provisioner
- CNPG storage docs: https://cloudnative-pg.io/documentation/current/storage/

---

*End of follow-up TODO v0.2 (CNPG 완료 후 실행 확정)*
