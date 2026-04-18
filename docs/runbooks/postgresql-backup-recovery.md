# PostgreSQL 백업 복구 Runbook

| 항목 | 값 |
|------|-----|
| **심각도** | Critical (데이터 복구는 모두 실전 상황) |
| **최종 수정** | 2026-04-19 |
| **상태** | ✅ Production (commit `d27d4eb`, `3fc4c05`, `77d1207`, `33dff43`) |
| **관련 리소스** | CronJob `apps/postgresql-backup`, PV `postgresql-backup-external-ssd`, R2 `homelab-postgresql-backup` |
| **카테고리** | 재해 복구 (DR) |

---

## 1. 백업 구조 개요

```
┌──────────────────────────────────────────────────────────────────┐
│  CronJob: postgresql-backup (매일 03:00 KST = 18:00 UTC)         │
│   image: postgres:18-alpine + rclone 1.69 (런타임 다운로드)       │
│   ttlSecondsAfterFinished: 600 (Job은 10분 뒤 정리)              │
└──────────────────────────────────────────────────────────────────┘
             │
             ├─── pg_dump -Fc  (DB별 custom format, 압축)
             ├─── pg_dumpall --globals-only  (role/grant)
             ▼
      /tmp/dumps/<db>-<TS>.dump  /tmp/dumps/globals-<TS>.sql
             │
             ├──► 로컬 복제 (hostPath → Mac 외장 SSD)
             │    /mnt/mac/Volumes/ukkiee/homelab/backups/postgresql/
             │      ├── daily/   (7일 보존)
             │      ├── weekly/  (28일 보존, 매주 일요일)
             │      └── monthly/ (180일 보존, 매월 1일)
             │
             └──► R2 오프사이트 (rclone copy, 3계층 lifecycle)
                  r2://homelab-postgresql-backup/
                    ├── daily/   (7일 자동 만료, Terraform lifecycle)
                    ├── weekly/  (28일 자동 만료)
                    └── monthly/ (180일 자동 만료)
```

### 1.1 파일 명명 규칙

```
<database_name>-<TS>.dump     # pg_dump -Fc 출력, DB별 1개
globals-<TS>.sql              # pg_dumpall --globals-only, 전체 1개

TS 형식: YYYYMMDDTHHMMSSZ (UTC)  예: 20260419T180005Z
```

### 1.2 복구 매체 선택 기준

| 시나리오 | 1차 소스 | 2차 소스 | 이유 |
|---|---|---|---|
| Pod 재시작 직후 | (복구 불필요) | - | Volume은 Retain + WaitForFirstConsumer, 데이터는 chart PVC에 유지 |
| 단일 테이블/DB 실수 삭제 | 로컬 SSD `daily/` | R2 `daily/` | 네트워크 없이 복구 가능, 대역폭 무료 |
| 전체 DB 날라감 (chart PVC 손상) | 로컬 SSD 최신 `daily/` | R2 `daily/` | 동일 |
| Mac 호스트 자체 장애 | R2 `daily/` | R2 `weekly/` 또는 `monthly/` | 외장 SSD 접근 불가 |
| 외장 SSD + Mac 동반 장애 | R2 `daily/` | - | R2가 유일한 소스 |
| 7일 이상 지난 데이터 필요 | 로컬 SSD `weekly/`/`monthly/` | R2 `weekly/`/`monthly/` | daily는 7일 후 삭제 |

---

## 2. 복구 전 공통 준비

### 2.1 현재 백업 상태 확인

```bash
# 1) 마지막 CronJob 성공 시각
kubectl get cronjob -n apps postgresql-backup \
  -o jsonpath='{.status.lastSuccessfulTime}{"\n"}'

# 2) 최근 Job 이력 (Failed/Succeeded 확인)
kubectl get jobs -n apps -l app.kubernetes.io/name=postgresql-backup \
  --sort-by=.metadata.creationTimestamp

# 3) 외장 SSD 로컬 백업 목록 (최신순)
ls -lht /Volumes/ukkiee/homelab/backups/postgresql/daily/ | head -10
ls -lht /Volumes/ukkiee/homelab/backups/postgresql/weekly/ | head -5
ls -lht /Volumes/ukkiee/homelab/backups/postgresql/monthly/ | head -3
```

### 2.2 R2 백업 목록 확인 (rclone 설치 필요)

```bash
# rclone 설치 확인
which rclone || brew install rclone

# 기존 설정이 없으면 SealedSecret 복호화해서 일회용 설정
# (실전에서는 Mac 로컬에 rclone config 영구 저장 권장)
export R2_ACCESS_KEY_ID=$(kubectl get secret -n apps postgresql-backup-r2 \
  -o jsonpath='{.data.access_key_id}' | base64 -d)
export R2_SECRET_ACCESS_KEY=$(kubectl get secret -n apps postgresql-backup-r2 \
  -o jsonpath='{.data.secret_access_key}' | base64 -d)
export R2_ENDPOINT=$(kubectl get secret -n apps postgresql-backup-r2 \
  -o jsonpath='{.data.endpoint}' | base64 -d)

cat > /tmp/rclone-r2.conf <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = $R2_ACCESS_KEY_ID
secret_access_key = $R2_SECRET_ACCESS_KEY
endpoint = $R2_ENDPOINT
region = auto
EOF

# 목록 조회
rclone --config /tmp/rclone-r2.conf lsl r2:homelab-postgresql-backup/daily/ | head -10
rclone --config /tmp/rclone-r2.conf lsl r2:homelab-postgresql-backup/weekly/ | head -5
rclone --config /tmp/rclone-r2.conf lsl r2:homelab-postgresql-backup/monthly/ | head -3
```

### 2.3 PostgreSQL 접속 정보

```bash
# 현재 postgres 사용자 비밀번호
PG_PASS=$(kubectl get secret -n apps postgresql-auth \
  -o jsonpath='{.data.postgres-password}' | base64 -d)

# PgAdmin/psql 접근 (클러스터 내부)
kubectl run --rm -it --image=postgres:18-alpine -n apps pg-shell --restart=Never -- \
  psql -h postgresql -U postgres
# 프롬프트에서 $PG_PASS 입력
```

---

## 3. 시나리오 A: 단일 DB 복구 (가장 흔함)

> **상황**: 애플리케이션이 실수로 테이블을 drop했거나 데이터 corruption. 해당 DB만 시점 이전으로 되돌리고 싶음.

### 3.1 복구 파일 선택

```bash
ls -lht /Volumes/ukkiee/homelab/backups/postgresql/daily/ | grep '<dbname>-'
# 예: appdb-20260418T180005Z.dump  (어제 백업)
```

### 3.2 임시 복구 DB 생성 후 검증 (권장)

```bash
PG_PASS=$(kubectl get secret -n apps postgresql-auth \
  -o jsonpath='{.data.postgres-password}' | base64 -d)

# 1) 임시 DB 생성
kubectl run --rm -it --image=postgres:18-alpine -n apps pg-shell --restart=Never -- \
  env PGPASSWORD="$PG_PASS" psql -h postgresql -U postgres \
  -c 'CREATE DATABASE appdb_restored;'

# 2) 백업 파일을 PgRestore Pod에서 접근 가능하도록 복사
#    (외장 SSD는 클러스터 내부에서 직접 읽을 수 없으므로 ephemeral 컨테이너 + stdin 사용)
cat /Volumes/ukkiee/homelab/backups/postgresql/daily/appdb-20260418T180005Z.dump | \
  kubectl run pg-restore-$$ --rm -i --image=postgres:18-alpine -n apps --restart=Never -- \
  env PGPASSWORD="$PG_PASS" pg_restore -h postgresql -U postgres \
  --dbname=appdb_restored --no-owner --no-privileges --verbose

# 3) 복구 DB 상태 검증
kubectl run --rm -it --image=postgres:18-alpine -n apps pg-shell --restart=Never -- \
  env PGPASSWORD="$PG_PASS" psql -h postgresql -U postgres -d appdb_restored \
  -c '\dt'  # 테이블 목록
```

### 3.3 swap — 검증 후 원본을 교체 (둘 중 하나 선택)

**경로 A (추천, 애플리케이션 downtime 필요): 원본 DB 백업 후 rename**

```bash
kubectl run --rm -it --image=postgres:18-alpine -n apps pg-shell --restart=Never -- \
  env PGPASSWORD="$PG_PASS" psql -h postgresql -U postgres <<'SQL'
-- 애플리케이션 connection 끊기 (1) kubectl scale, (2) revoke connect
ALTER DATABASE appdb CONNECTION LIMIT 0;
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='appdb';

ALTER DATABASE appdb RENAME TO appdb_broken_20260419;
ALTER DATABASE appdb_restored RENAME TO appdb;

-- 연결 제한 해제
ALTER DATABASE appdb CONNECTION LIMIT -1;
SQL

# 애플리케이션 Pod 재시작
kubectl rollout restart deploy/<app-name> -n apps
```

**경로 B (downtime 최소, 파티셔닝·외부 참조 주의): 테이블만 교체**

```sql
-- 원본 DB 접속 후
BEGIN;
ALTER TABLE broken_table RENAME TO broken_table_backup;
-- appdb_restored의 테이블을 pg_dump로 덤프 후 여기 import (번거로움)
COMMIT;
```

→ 경로 A가 안전·명확.

### 3.4 검증

```bash
# appdb가 정상 동작하는지
kubectl run --rm -it --image=postgres:18-alpine -n apps pg-shell --restart=Never -- \
  env PGPASSWORD="$PG_PASS" psql -h postgresql -U postgres -d appdb \
  -c 'SELECT count(*) FROM <critical_table>;'

# 애플리케이션 헬스체크
kubectl get pods -n apps -l app=<app-name>
```

### 3.5 정리

```sql
-- 문제 없다면 1주일 후 broken DB 삭제 (그 전까진 롤백 보험)
-- DROP DATABASE appdb_broken_20260419;
```

---

## 4. 시나리오 B: 전체 DB 복구 (chart PVC 손상)

> **상황**: PostgreSQL Pod가 기동 실패 + PVC 데이터 corruption 또는 실수 삭제. 전체를 최근 백업 시점으로 되돌림.

### 4.1 Pod 중지 및 현재 PVC 확보

```bash
# 1) ArgoCD sync 일시 중지 (자동 재시도 방지)
kubectl patch application postgresql -n argocd --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'

# 2) StatefulSet 스케일 다운
kubectl scale sts postgresql -n apps --replicas=0
kubectl wait --for=delete pod/postgresql-0 -n apps --timeout=60s

# 3) 현재 PVC를 잠시 보존 (삭제하지 말 것 — 롤백 보험)
kubectl get pvc -n apps -l app.kubernetes.io/name=postgresql
# → data-postgresql-0 : Retain 정책으로 PV 유지됨
```

### 4.2 globals(role/grant) 선행 복구

globals가 없으면 DB 복구 시 role 매핑 실패.

```bash
PG_PASS=$(kubectl get secret -n apps postgresql-auth \
  -o jsonpath='{.data.postgres-password}' | base64 -d)

# 새 PostgreSQL 기동 (빈 PVC)
kubectl scale sts postgresql -n apps --replicas=1
kubectl wait --for=condition=ready pod/postgresql-0 -n apps --timeout=180s

# globals 복구
cat /Volumes/ukkiee/homelab/backups/postgresql/daily/globals-20260418T180005Z.sql | \
  kubectl run pg-restore-globals-$$ --rm -i --image=postgres:18-alpine -n apps --restart=Never -- \
  env PGPASSWORD="$PG_PASS" psql -h postgresql -U postgres -f -
```

### 4.3 DB별 복구

```bash
for DB in appdb analytics whatever; do
  DUMP="/Volumes/ukkiee/homelab/backups/postgresql/daily/${DB}-20260418T180005Z.dump"
  [ -f "$DUMP" ] || { echo "skip $DB"; continue; }

  # DB 생성
  kubectl run --rm -it --image=postgres:18-alpine -n apps pg-shell --restart=Never -- \
    env PGPASSWORD="$PG_PASS" psql -h postgresql -U postgres \
    -c "CREATE DATABASE $DB;"

  # pg_restore
  cat "$DUMP" | \
    kubectl run pg-restore-$DB-$$ --rm -i --image=postgres:18-alpine -n apps --restart=Never -- \
    env PGPASSWORD="$PG_PASS" pg_restore -h postgresql -U postgres \
    --dbname=$DB --no-owner --no-privileges --verbose
done
```

### 4.4 ArgoCD sync 재활성

```bash
kubectl patch application postgresql -n argocd --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

### 4.5 검증

- 섹션 3.4와 동일 + 모든 애플리케이션 Pod rollout 후 헬스체크

---

## 5. 시나리오 C: 외장 SSD 접근 불가 — R2에서 복구

> **상황**: Mac 자체 장애 또는 외장 SSD 분실/고장. 오프사이트 R2가 유일한 소스.

### 5.1 다른 Mac/서버에서 R2 다운로드

```bash
# 섹션 2.2의 rclone 설정 완료 후
mkdir -p /tmp/pgbackup-restore
rclone --config /tmp/rclone-r2.conf copy r2:homelab-postgresql-backup/daily/ /tmp/pgbackup-restore/

ls -lht /tmp/pgbackup-restore/ | head -20
```

### 5.2 복구 절차는 시나리오 A/B와 동일

`/Volumes/ukkiee/homelab/backups/postgresql/daily/` 경로를 `/tmp/pgbackup-restore/` 로만 치환.

### 5.3 R2 lifecycle 주의

- `daily/` 는 7일 후 R2 lifecycle이 자동 삭제 — 장애가 7일 넘어가면 `weekly/` 또는 `monthly/` 사용
- `weekly/` 는 28일, `monthly/` 는 180일 보존

```bash
rclone --config /tmp/rclone-r2.conf copy r2:homelab-postgresql-backup/weekly/ /tmp/pgbackup-restore/
# 또는
rclone --config /tmp/rclone-r2.conf copy r2:homelab-postgresql-backup/monthly/ /tmp/pgbackup-restore/
```

---

## 6. 수동 백업 생성 (대형 변경 직전)

스키마 마이그레이션 직전처럼 "이 순간 상태"를 확보하고 싶을 때 CronJob을 수동 트리거.

```bash
# 1회성 Job 생성 (CronJob의 spec을 복제하되 schedule 무시)
kubectl create job --from=cronjob/postgresql-backup -n apps \
  postgresql-backup-manual-$(date -u +%Y%m%d%H%M)

# 진행 로그
kubectl logs -n apps -f -l job-name=postgresql-backup-manual-<TS>

# 완료 확인
kubectl get jobs -n apps | grep postgresql-backup-manual
```

결과물은 자동 Job과 동일한 경로에 저장됨 (daily/ + R2 daily/).

---

## 7. 백업 무결성 정기 점검

### 7.1 월 1회 복구 훈련 권장

- 복구를 한 번도 안 해본 백업은 "존재한다"는 보장밖에 없음
- 매월 임시 DB로 복구 → schema + 샘플 row count 검증

### 7.2 간이 자동 점검 (PromQL)

Grafana 알람 `backup-alerts` 그룹이 자동 감시 (commit `alerting.yaml` 2026-04-19 업데이트):

| 알람 UID | 조건 | 심각도 |
|---|---|---|
| `postgresql-backup-failed` | 15분 내 실패 Job 존재 | critical |
| `postgresql-backup-missing` | 25시간+ 성공 시각 없음 | critical |
| `postgresql-backup-suspended` | CronJob suspend=true | warning |

### 7.3 R2 용량 확인

```bash
rclone --config /tmp/rclone-r2.conf size r2:homelab-postgresql-backup/
# daily + weekly + monthly 합산
```

R2 무료 한도: 10 GB (Standard) + 1백만 Class A operation/월. 홈랩 규모에선 한참 여유.

---

## 8. 알려진 제약

### 8.1 rclone은 런타임 다운로드 (초기 Job마다 ~30MB 트래픽)

- alpine apk에 rclone이 없거나 구버전이라 공식 binary를 curl로 다운로드
- P8 (GHCR 커스텀 이미지) 완료 시 이 지연 제거 예정

### 8.2 `hostPath` 기반 PV는 Pod 스케줄링 노드 고정

- 현재 홈랩은 K3s 단일 노드라 문제 없음
- 다중 노드 확장 시 PostgreSQL Pod와 CronJob이 같은 노드에 스케줄되도록 nodeSelector 또는 NFS 전환 필요

### 8.3 외장 SSD 마운트 해제 시 백업 실패

- Mac에서 SSD를 eject 했다면 CronJob은 `/backups` 경로에 쓰기 실패 → `postgresql-backup-failed` 알람
- OrbStack은 Mac 볼륨을 `/mnt/mac/` 로 bind mount. Mac 측 마운트 유지 확인 필요

### 8.4 backups 경로는 수동 mkdir 필요 (memory: project_external_ssd_access)

```bash
# 외장 SSD 최초 연결 시, Mac 호스트에서 1회 수행
mkdir -p /Volumes/ukkiee/homelab/backups/postgresql/{daily,weekly,monthly}
chmod -R 755 /Volumes/ukkiee/homelab/backups/postgresql/
```

### 8.5 복구 파일 전송은 Pod stdin 경유 (외장 SSD → Pod)

- 외장 SSD는 클러스터 내부에서 직접 읽을 수 없음 (CronJob만 /backups mount)
- 복구 시 Mac → `cat file | kubectl run ... -i` 로 stdin 스트리밍
- 대용량 (>10GB) DB는 네트워크 경유 시간 고려 필요 — 미리 PV로 복사해두는 것이 빠를 수 있음

---

## 9. 관련 문서 / 코드

- 매니페스트: `manifests/apps/postgresql/backup-cronjob.yaml`, `backup-storage.yaml`, `sealed-secret-r2.yaml`
- Terraform (R2 버킷 + lifecycle): `terraform/r2.tf` (commit `77d1207`)
- 알람 규칙: `manifests/monitoring/grafana/alerting.yaml` (group `backup-alerts`)
- 관련 Runbook: [PostgreSQL Helm Upgrade](./postgresql-helm-upgrade.md)
- 관련 memory: `project_external_ssd_access.md` (외장 SSD 경로/권한 제약)
