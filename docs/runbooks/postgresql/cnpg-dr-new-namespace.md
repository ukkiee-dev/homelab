# CNPG 별도 namespace 복구 — DR / 감사 시나리오

> **초안 작성일**: 2026-04-20 (Phase 4 Task 4.7, PR #? 진행 중)
> **완성 예정**: Phase 9 (Phase 4 드라이런 실측값 반영 후)
> **Reference**: design.md v0.4 §8.2 (동일 namespace) 와 **다른** 시나리오 · plan.md Task 4.6b

## 사용 사례

- **감사 / compliance**: 특정 시점 데이터 조사 (법적 요청 등). 원본 cluster 영향 없이 과거 시점 DB 띄우기
- **DR replica 검증**: 월 1회 주기 복구 테스트 (`dr-verification` 스킬)
- **데이터 비교**: 원본 운영 cluster 와 시점 복구 데이터 병행 비교
- **schema migration 롤백 전 preview**: 복구 가능성을 원본 영향 없이 실전 확인

## 동일 namespace 복구 ([cnpg-pitr-restore.md](cnpg-pitr-restore.md)) 와의 차이

|  | 동일 namespace | 별도 namespace (이 Runbook) |
|---|---|---|
| 원본 cluster | 삭제됨 | **유지** |
| 복구 대상 | 원본과 같은 이름·ns | 새 namespace (또는 suffix 이름) |
| ArgoCD 처리 | selfHeal off PR 필요 | 불필요 (신규 리소스) |
| SealedSecret | 기존 재사용 | **namespace-scoped 라 재seal 필수** |
| Use case | 평시 사고 대응 (데이터 손상) | DR 검증·감사·비교 |

## 전제 조건

- CNPG operator + plugin-barman-cloud 정상 (Phase 2)
- 원본 Cluster 가 정상 WAL archive 중 (`<project>-backup` ObjectStore)
- R2 credential 원본 (`_workspace/cnpg-migration/02_r2-credentials.txt`) 로 접근 가능
- 로컬 `kubeseal v0.36.1` 설치, `--controller-namespace kube-system --controller-name sealed-secrets` 접근 가능

## 절차

### Step 1 — 복구용 namespace 생성 + R2 credential re-seal

SealedSecret 은 namespace-scoped 이므로 복구 namespace 전용으로 신규 seal.

```bash
RESTORE_NS=<project>-restore
kubectl create ns "$RESTORE_NS"

# R2 credential 평문 로드
source _workspace/cnpg-migration/02_r2-credentials.txt

cat > /tmp/r2-backup-restore.yaml <<EOF
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: r2-pg-backup
  namespace: ${RESTORE_NS}
stringData:
  ACCESS_KEY_ID: "${R2_ACCESS_KEY_ID}"
  SECRET_ACCESS_KEY: "${R2_SECRET_ACCESS_KEY}"
EOF

kubeseal --controller-namespace kube-system \
         --controller-name sealed-secrets \
         --format=yaml \
         < /tmp/r2-backup-restore.yaml \
         > /tmp/r2-backup-restore.sealed.yaml
rm /tmp/r2-backup-restore.yaml

kubectl apply -f /tmp/r2-backup-restore.sealed.yaml
sleep 10
kubectl -n "$RESTORE_NS" get secret r2-pg-backup -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d | cut -c1-5
# Expected: 5자 접두사 출력 → unseal 성공
```

### Step 2 — 복구 Cluster 선언

원본 `<project>-pg` 와 **같은 이름** 사용 가능 (namespace 가 다르므로). 또는 suffix (`-restore`) 로 구분.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: <project>-pg
  namespace: <project>-restore
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:<PIN>
  storage:
    size: 5Gi            # 원본과 다를 수 있음 (복구 목적 용)
    storageClass: local-path
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: 500m, memory: 512Mi }
  bootstrap:
    recovery:
      source: <project>-pg-backup-source
      recoveryTarget:
        targetTime: "<TARGET_TIME UTC>"
  externalClusters:
    - name: <project>-pg-backup-source
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: <project>-backup     # 원본 ObjectStore 이름
          serverName: <project>-pg               # 원본 Cluster 이름
```

> **중요**: `externalClusters[0].plugin.parameters` 는 **원본 cluster 의 식별값** (serverName, barmanObjectName). 원본 R2 prefix 에서 base+WAL 을 읽어옴.

Apply:
```bash
kubectl apply -f manifests/apps/<project>-restore/cluster-recovery.yaml
kubectl -n "$RESTORE_NS" get cluster -w
# Wait until phase=Cluster in healthy state (5-10분, base 복원 + WAL replay)
```

### Step 3 — 복구 데이터 검증

```bash
RESTORE_PRIMARY=$(kubectl -n "$RESTORE_NS" get pod -l cnpg.io/cluster=<project>-pg,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$RESTORE_NS" exec "$RESTORE_PRIMARY" -c postgres -- psql -U postgres -d <db> -c "
  SELECT pg_postmaster_start_time() AS started,
         now() AS current_utc,
         count(*) AS rows_in_critical_table
  FROM <critical_table>;
"
```

원본과 **완전히 분리**된 instance 이므로 write 가능 (원본 영향 없음).

### Step 4 — 작업 완료 후 cleanup

```bash
kubectl delete ns "$RESTORE_NS"
# PVC/PV 자동 정리 (local-path Delete policy)
```

필요 시 DB dump 를 보관하려면 cleanup 전에:
```bash
kubectl -n "$RESTORE_NS" exec "$RESTORE_PRIMARY" -c postgres -- pg_dump -U postgres <db> | gzip > /tmp/<project>-restore-$(date -u +%Y%m%d).sql.gz
# 외장 SSD 또는 R2 archive prefix 로 이동
```

## 주의 사항

- **원본 ObjectStore 는 read-only 로 사용** — 복구 cluster 가 새 WAL 을 원본 prefix 에 쓰지 않음 (recovery-only mode). 다만 recovery cluster 자체도 WAL archive 를 시도할 수 있으니 `spec.plugins` 블록 **제외** 하거나 별도 ObjectStore 지정.
  - 이 Runbook 의 예시 YAML 은 `plugins` 미포함 → recovery cluster 는 archive 안 함 (단순 조회용)
- **TARGET_TIME 선택**: 너무 오래된 시점은 base backup retentionPolicy(14d) 로 이미 삭제된 구간. `kubectl cnpg status` 의 `FirstRecoverabilityPoint` 이후 시점만 가능
- **시간 소요**: DB 크기·WAL 개수 비례. 홈랩 소규모 기준 5-15분 예상 (Phase 4 드라이런 실측값은 Phase 9 에 박제)

## Phase 4 드라이런 실측값 (Phase 9 에서 채움)

| 항목 | 값 |
|---|---|
| base backup 크기 | <TBD MB> |
| WAL 개수 | <TBD segments> |
| recovery 완료 소요 | <TBD min> |
| verify 쿼리 응답 시간 | <TBD ms> |

## 참고

- design.md v0.4 §8.2 (동일 namespace 절차 · 다른 시나리오지만 같은 bootstrap.recovery 메커니즘)
- Phase 4 Task 4.6b 드라이런 결과: `_workspace/cnpg-migration/05_pitr-drills.md`
- 동일 namespace 복구: [cnpg-pitr-restore.md](cnpg-pitr-restore.md)
