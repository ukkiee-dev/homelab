# CNPG PITR 복구 — 동일 namespace 시점복구

> **초안 작성일**: 2026-04-20 (Phase 4 Task 4.7, PR #? 진행 중)
> **완성 예정**: Phase 9 (Phase 4 드라이런 실측값 반영 후)
> **Reference**: design.md v0.4 §8.2 · plan.md Task 4.6a

## 증상

다음 중 하나 발생 시 이 Runbook 적용:
- 데이터 손상 (잘못된 UPDATE / DELETE / DROP 후 발견)
- schema migration 실패로 되돌릴 수 없는 상태
- application bug 으로 논리적 데이터 오염
- 특정 시점 이전 상태로 되돌려야 하는 운영 결정

## 전제 조건

- CNPG operator + plugin-barman-cloud 정상 (Phase 2 완료)
- 대상 Cluster 가 ObjectStore (R2) 로 WAL archive 중
- 복구 목표 시점 `TARGET_TIME` (UTC) 확정
- R2 에 해당 시점을 포함하는 base backup + WAL 존재 확인
- **주의**: 동일 namespace 에 recovery Cluster 를 재선언 — 원본 데이터는 완전히 대체됨

## 진단

### 1. 현재 Cluster 상태

```bash
NS=<project>
CLUSTER=<project>-pg

kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{"phase:"}{.status.phase}{" ready:"}{.status.readyInstances}/{.status.instances}{"\n"}'
# 예: phase=Cluster in healthy state  ready=1/1
```

### 2. PV reclaim policy 확인 (design §8.2 Step 0)

```bash
PV_NAME=$(kubectl -n "$NS" get pvc -l cnpg.io/cluster="$CLUSTER" -o jsonpath='{.items[0].spec.volumeName}')
kubectl get pv "$PV_NAME" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'
# Expected: Delete (local-path 기본). Retain 이면 Step 3 전에 수동 kubectl delete pv 필요 (동일 이름 재사용 충돌 방지).
```

### 3. R2 에 backup 존재 여부

```bash
kubectl cnpg status "$CLUSTER" -n "$NS"      # FirstRecoverabilityPoint / LastArchivedWAL 확인
# 또는 rclone 으로 직접 조회
rclone ls r2:homelab-db-backups/${CLUSTER}/base/ | head
rclone ls r2:homelab-db-backups/${CLUSTER}/wals/ | head
```

## 해결 (design §8.2 5단계 PR 흐름)

### Step 1 — ArgoCD 일시 unmanage (Git PR ①)

대상 Application 의 `spec.syncPolicy.automated.selfHeal` 을 `false` 로 변경하거나 `automated: null`.

- [ ] PR ① 생성 + 리뷰 + merge
- [ ] ArgoCD reconcile 대기 (≤ 3 min, 또는 `argocd app get` 확인)
- [ ] `argocd app sync <app> --dry-run` 결과로 예상 diff 확인

**Phase 3 PoC (pg-trial) 는 ArgoCD 관리 밖**이라 이 Step 은 kubectl 직접 조작으로 치환 가능.

### Step 2 — 원본 Cluster 삭제

```bash
kubectl -n "$NS" delete cluster "$CLUSTER"
kubectl -n "$NS" wait --for=delete cluster/"$CLUSTER" --timeout=5m

# PVC 는 finalizer cascade 로 자동 삭제되지 않을 수 있음 — 명시적 정리
kubectl -n "$NS" delete pvc -l cnpg.io/cluster="$CLUSTER"

# PV 자동 삭제 확인 (local-path Delete 정책)
sleep 15
kubectl get pv | grep "$CLUSTER" || echo "PV 정리 완료"
```

**Webhook 데드락 발생 시**: `kubectl -n cnpg-system scale deploy/cnpg-cloudnative-pg --replicas=0` → delete 재시도 → scale 1 복원 (design §9 M3).

### Step 3 — recovery Cluster 선언 (Git PR ②)

`common/cluster.yaml` 에 `spec.bootstrap.recovery` + `spec.externalClusters[]` 블록 추가:

```yaml
spec:
  # ... 기존 spec 유지 (instances, imageName, storage, resources, monitoring, managed.roles, plugins) ...
  bootstrap:
    recovery:
      source: <cluster>-backup-source
      recoveryTarget:
        targetTime: "2026-04-25 14:30:00+00"   # UTC
  externalClusters:
    - name: <cluster>-backup-source
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: <cluster>-backup
          serverName: <cluster>
```

- [ ] PR ② merge
- [ ] 수동 `argocd app sync <app>` (selfHeal=false 라 자동 trigger 안 됨)
- [ ] `kubectl cnpg status <cluster>` 로 복구 진행 확인 (base 복원 + WAL replay, 5-10분 예상)

### Step 4 — managed.roles · Database 재적용 + 앱 rolling restart

- [ ] managed.roles 및 Database CR 은 이미 Git 에 있으므로 operator 가 자동 reconcile
- [ ] 앱 Deployment rolling restart: `kubectl -n "$NS" rollout restart deploy/<app>`
- [ ] Secret 참조 변경 없으므로 env 재주입만으로 재연결

### Step 5 — selfHeal 복원 (Git PR ③)

- [ ] `spec.bootstrap.recovery` + `spec.externalClusters[]` 블록 **제거**
- [ ] `spec.syncPolicy.automated.selfHeal: true` 원복
- [ ] PR ③ merge → 정상 selfHeal 상태로 복귀

## 검증

1. **데이터 포인트 확인**

```bash
PRIMARY=$(kubectl -n "$NS" get pod -l cnpg.io/cluster="$CLUSTER",cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$NS" exec "$PRIMARY" -c postgres -- psql -U postgres -d <db> -c "SELECT * FROM <critical_table> ORDER BY id DESC LIMIT 5;"
# 복구 목표 시점 이후 행이 없음을 확인
```

2. **role 로 쓰기 검증**

```bash
PASS=$(kubectl -n "$NS" get secret "${CLUSTER}-<role>-credentials" -o jsonpath='{.data.password}' | base64 -d)
kubectl -n "$NS" run verify --rm -it --restart=Never --image=postgres:16-alpine \
  --env="PGPASSWORD=${PASS}" \
  -- psql "postgresql://<role>@${CLUSTER}-rw:5432/<db>?sslmode=require" -c "SELECT 1;"
```

3. **backup 정상 재개**

- [ ] ScheduledBackup 다음 실행 시각 확인: `kubectl -n "$NS" get scheduledbackup -o jsonpath='{.items[*].status.nextScheduleTime}'`
- [ ] WAL archive 확인: 다음 24h 안에 R2 `wals/` prefix 에 새 세그먼트 업로드

## Post-mortem 기록

- [ ] 이 Runbook 부록에 실행 기록 (날짜, TARGET_TIME, 소요 시간, 복구 데이터 건수)
- [ ] 복구 원인 (데이터 손상 원인) 별도 incident report

## Phase 4 드라이런 실측값 (Phase 9 에서 채움)

| 항목 | 값 |
|---|---|
| Step 2 cluster delete 소요 | <TBD min> |
| Step 3 recovery 완료 소요 | <TBD min> (base <X>MB + WAL <Y>개) |
| 전체 복구 시간 RTO | <TBD min> |
| RPO (마지막 WAL archive 기준) | <TBD min> |

## 참고

- design.md v0.4 §8.2 (5단계 PR 흐름 상세)
- Phase 4 Task 4.6a 드라이런 결과: `_workspace/cnpg-migration/05_pitr-drills.md`
- 별도 namespace 로 DR replica 복구: [cnpg-dr-new-namespace.md](cnpg-dr-new-namespace.md)
