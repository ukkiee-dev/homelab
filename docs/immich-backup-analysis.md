# Immich + 외장 SSD 구현 계획 (최종)

> 작성일: 2026-03-25 | 최종 수정: 2026-03-25
> 대상: Mac Mini M4 (OrbStack K3s, 내장 512GB) + SK hynix P31 2TB (TB4)
> 선행 문서: `docs/implementation-plan.md`, `docs/disaster-recovery.md`

---

## 결정 요약

| 결정 항목 | 결론 | 근거 |
|-----------|------|------|
| 운영 환경 | **OrbStack K3s on macOS 유지** | macOS + VirtioFS로 충분, 별도 Linux 전환 불필요 |
| SSD 연결 | **Thunderbolt 4 (40Gbps, 후면 포트)** | SMART + TRIM 네이티브 지원 확인 완료 |
| 파일시스템 | **APFS** | TRIM 자동, CoW 데이터 보호, 스냅샷, 네이티브 암호화 |
| 데이터 배치 | **하이브리드** (DB 내장 / 미디어 외장) | PostgreSQL은 반드시 로컬 SSD (Immich 공식 요구사항) |
| Pod ↔ SSD | **VirtioFS bind mount** | 순차 I/O 중심의 미디어 워크로드에 충분 (75-95% native) |
| 백업 전략 | **2-1-1 (사실상)** + R2 오프사이트 | 동일 디스크 내 로컬 Restic은 속도 버퍼일 뿐, R2가 유일한 보호막 |

---

## 1. 현재 하드웨어 구성

### 1-A. 확인된 장비 스펙

| 항목 | 상세 |
|------|------|
| **외장 SSD** | SK hynix Gold P31 2TB (`SHGP31-2000GM`) |
| SSD 인터페이스 | PCIe Gen 3 x4, NVMe |
| SSD 시리얼 | `AJC3N421310303H3E` |
| **인클로저** | TB4 인클로저 (`TBU405`) |
| 연결 속도 | **Thunderbolt 4, 40 Gb/s** (후면 포트 2) |
| SMART 상태 | **Verified** |
| TRIM 지원 | **Yes** |
| 마운트 포인트 | `/Volumes/ukkiee` |
| 파일시스템 | APFS (Case-insensitive) |
| 볼륨 UUID | `9DE994D4-7D54-4DB0-90B2-032E687E359F` |
| 현재 사용량 | ~720 KB (거의 비어있음) |
| EFI 파티션 잔재 | `disk4s1` WINTOUSB (105 MB) — 이전 용도 잔재, 무해하나 정리 가능 |
| **내장 SSD** | Apple SSD 512GB (`APPLE SSD AP0512Z`) |
| **pmset 설정** | `disksleep=0, sleep=0, displaysleep=0` (설정 완료) |

### 1-B. 연결 상태

```
Mac Mini M4 후면:
  [전원] [Ethernet] [HDMI] [TB4①] [TB4② ← TBU405 연결됨] [TB4③]
                                     40 Gb/s 확인
```

### 1-C. 확인 사항

- SMART: `diskutil info` → "SMART Status: Verified" 확인
- TRIM: `system_profiler SPNVMeDataType` → "TRIM Support: Yes" 확인
- smartctl: **미설치** → `brew install smartmontools` 필요 (상세 SMART 데이터용)

---

## 2. 파일시스템 + macOS 설정

### 2-A. 파일시스템 (설정 완료)

SSD는 이미 APFS 포맷 완료. 볼륨명 `ukkiee`, 마운트 포인트 `/Volumes/ukkiee`.

**APFS 선택 이유:**

| 기능 | APFS | ExFAT | ext4 (FUSE) |
|------|:---:|:---:|:---:|
| TRIM 자동 수행 | **자동** | 미지원 | 미지원 |
| CoW (전원 장애 보호) | **지원** | 없음 | 없음 (macOS에서) |
| 스냅샷 | **지원** | 없음 | 없음 |
| 네이티브 암호화 | **FileVault** | 없음 | 없음 |
| macOS 통합 | **최상** | 좋음 | 매우 나쁨 |

### 2-B. macOS 서버 설정

```bash
# ✅ 설정 완료 확인됨:
# disksleep=0, sleep=0, displaysleep=0

# 추가 필요:
sudo mdutil -i off /Volumes/ukkiee                # Spotlight 인덱싱 비활성화
sudo tmutil addexclusion /Volumes/ukkiee           # Time Machine 제외
brew install smartmontools                          # 상세 SMART 모니터링
```

### 2-C. 기존 Linux 계획 → macOS 대체 매핑

| 기존 계획 (Linux) | macOS 대체 | 상태 |
|---|---|:---:|
| `/etc/udev/rules.d/` | launchd plist (SSD 감시) | 해결 |
| `/etc/fstab` + ext4 | APFS + macOS 자동마운트 | 해결 |
| systemd mount unit | launchd + diskutil mount | 해결 |
| `Before=k3s.service` | OrbStack 시작 후 자동 (제어 불필요) | 해결 |
| `/dev/sda` | `/dev/disk4` (실제 확인됨) | 해결 |

### 2-D. 구현 중 발견된 트러블슈팅 기록

#### 외장 SSD Permission Denied (macOS TCC)

**증상:** `/Volumes/ukkiee`에 `mkdir`, `chmod`, `ls` 모두 `Operation not permitted` — `sudo`로도 불가.
Docker bind mount에서도 쓰기 시 `Permission denied`.

**원인:** macOS TCC(Transparency, Consent, and Control) 보안 정책이 외장 볼륨 접근을 차단.
터미널 앱과 OrbStack 모두 Full Disk Access 권한이 없었음.

**해결:**
1. System Settings → Privacy & Security → Full Disk Access
2. **Ghostty** (터미널 앱) + **OrbStack** 추가/활성화
3. 터미널 + OrbStack 재시작
4. `sudo diskutil enableOwnership /Volumes/ukkiee` 실행 (볼륨 소유권 활성화)
5. 이후 `mkdir`, `chmod`, Docker/K8s bind mount 모두 정상 동작

> 새 Mac 또는 클러스터 재구축 시 반드시 이 설정을 먼저 수행해야 함.

#### 새 서브도메인 DNS 캐시 문제 (AdGuard NXDOMAIN 캐시)

**증상:** Cloudflare에 `photos.ukkiee.dev` DNS + Tunnel Public Hostname 추가 후에도 Mac에서 접속 불가.
`dig` 명령은 정상 해석되지만 `curl`/브라우저에서 `Could not resolve host`.

**원인:** Tailscale DNS(100.100.100.100) → AdGuard를 거치는 구조에서,
DNS 레코드 추가 전에 발생한 NXDOMAIN 응답이 AdGuard에 캐시됨.
`dig`은 직접 resolver를 지정하므로 우회되지만, 시스템 DNS(curl/브라우저)는 캐시된 NXDOMAIN을 반환.

**해결:**
1. AdGuard 웹 UI → Settings → DNS settings → DNS cache configuration → **Clear cache**
2. Mac DNS 캐시도 플러시: `sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder`
3. 긴급 우회: `/etc/hosts`에 `104.21.14.177 photos.ukkiee.dev` 추가 (임시)

> 새 서브도메인 추가 시 항상 AdGuard 캐시를 먼저 비울 것.
> Cloudflare Tunnel Public Hostname 추가 시 DNS CNAME이 자동 생성되므로 별도 DNS 레코드 추가 불필요.

---

## 3. 데이터 배치 전략 (하이브리드)

### 3-A. 핵심 원칙

> **PostgreSQL은 반드시 로컬 SSD에 배치** (Immich 공식 요구사항: "The database must be on a local SSD, never a network share")
> **미디어 파일은 외장 SSD에 배치** (순차 I/O 중심, VirtioFS 오버헤드 무시 가능)

### 3-B. 배치 다이어그램

```
Mac Mini 내장 SSD                     외장 NVMe SSD 2TB (TB4)
┌───────────────────────────┐         ┌──────────────────────────────────┐
│ OrbStack 볼륨              │         │ /Volumes/ukkiee               │
│ (Linux-native I/O)        │         │ (APFS, VirtioFS bind mount)      │
│                           │         │                                  │
│ ├── PostgreSQL    ~5 Gi   │         │ /Volumes/ukkiee/immich/       │
│ │   (Immich 메타 + 벡터)  │         │ ├── library/      ← 원본 사진    │
│ │   shm_size: 128Mi       │         │ ├── thumbs/       ← 썸네일+미리보기│
│ ├── Redis         ~1 Gi   │         │ ├── encoded-video/ ← 트랜스코딩   │
│ │   (캐시 + 작업 큐)      │         │ ├── upload/       ← 업로드 버퍼   │
│ └── ML 모델 캐시  ~3 Gi   │         │ └── profile/      ← 프로필 이미지 │
│     (CLIP + 얼굴 인식)    │         │                                  │
│                           │         │ /Volumes/ukkiee/backups/      │
│ 합계: ~9 Gi               │         │ ├── pgdump/       ← DB 덤프      │
│ (512GB 내장 SSD 여유 충분) │         │ └── restic/       ← 로컬 Restic  │
└───────────────────────────┘         │                                  │
                                      │ 용량 배분:                        │
                                      │   immich:  ~1,400 Gi             │
                                      │   backups:   ~350 Gi             │
                                      │   여유:       ~50 Gi             │
                                      └──────────────────────────────────┘
```

### 3-C. 용량 검증

**내장 SSD (512GB, `APPLE SSD AP0512Z`):**

| 항목 | 용량 | 비고 |
|------|-----:|------|
| macOS 시스템 | ~30 Gi | |
| OrbStack 엔진 + 이미지 | ~15 Gi | K3s + 컨테이너 이미지 |
| K8s 인프라 PVC (Phase 1~6) | ~41 Gi | implementation-plan.md 기준 |
| Immich PostgreSQL | ~5 Gi | 공식 문서: 1-3 Gi 일반, 벡터 포함 시 +α |
| Immich Redis | ~1 Gi | 캐시 + 큐 |
| Immich ML 캐시 | ~3 Gi | CLIP ~600MB + 얼굴인식 ~1GB |
| 기타 (Homebrew, 개발도구) | ~20 Gi | |
| **합계** | **~115 Gi** | |
| **512GB 여유** | **~350 Gi** | 매우 넉넉 |

**외장 SSD (2TB, APFS 포맷 후 ~1,800 Gi):**

| 항목 | 용량 | 산출 근거 |
|------|-----:|----------|
| 원본 사진/동영상 | ~1,200 Gi | 라이브러리 최대 |
| 썸네일 + 트랜스코딩 | ~240 Gi | 원본의 10-20% (Immich 공식) |
| Restic 로컬 repo | ~300 Gi | 원본의 ~25% (dedup 적용) |
| pgdump | ~5 Gi | DB 덤프 7일치 |
| **합계** | **~1,745 Gi** | |
| **여유** | **~55 Gi** | |

> **주의:** 라이브러리가 1.2TB를 초과하면 Restic 로컬 repo 축소 또는 R2 전용 전환 필요.

### 3-D. 왜 썸네일도 외장인가

PostgreSQL만 내장에 두고 썸네일을 포함한 모든 미디어를 외장에 배치하는 이유:

1. **Immich의 UPLOAD_LOCATION은 단일 경로**: `library/`, `thumbs/`, `encoded-video/`가 모두 하위 디렉토리로 관리됨. 분리 마운트는 복잡도만 증가.
2. **썸네일은 순차 읽기**: 갤러리 스크롤 시 각 파일(50KB-1MB)을 순차 로딩. VirtioFS 경유해도 개별 파일 로딩 2-5ms → 50장 로딩 <100ms.
3. **브라우저 + Immich HTTP 캐싱**: 한 번 로딩된 썸네일은 브라우저 캐시에 저장. 반복 로딩 없음.
4. **내장 SSD 오염 방지**: 미디어 데이터를 내장에 두면 OrbStack/K8s 인프라와 혼재. 외장 분리가 관리상 깔끔.

---

## 4. K8s 매니페스트 설계

### 4-A. PersistentVolume

```yaml
# 외장 SSD — Immich 미디어 (bind mount via VirtioFS)
apiVersion: v1
kind: PersistentVolume
metadata:
  name: immich-media-pv
spec:
  capacity:
    storage: 1400Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: external-ssd
  hostPath:
    path: /Volumes/ukkiee/immich   # macOS 경로 (대소문자 정확히)
    type: Directory
---
# 외장 SSD — 백업 저장소
apiVersion: v1
kind: PersistentVolume
metadata:
  name: immich-backup-pv
spec:
  capacity:
    storage: 350Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: external-ssd
  hostPath:
    path: /Volumes/ukkiee/backups
    type: Directory
---
# 내장 SSD — PostgreSQL (OrbStack native volume)
apiVersion: v1
kind: PersistentVolume
metadata:
  name: immich-postgres-pv
spec:
  capacity:
    storage: 10Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: internal-ssd
  hostPath:
    path: /var/lib/immich-postgres    # OrbStack Linux 내부 경로
    type: DirectoryOrCreate
---
# 내장 SSD — ML 모델 캐시
apiVersion: v1
kind: PersistentVolume
metadata:
  name: immich-ml-cache-pv
spec:
  capacity:
    storage: 5Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: internal-ssd
  hostPath:
    path: /var/lib/immich-ml-cache
    type: DirectoryOrCreate
```

> **교차검증 완료:** OrbStack에서 `/Volumes/ukkiee` 경로의 bind mount는 정상 동작.
> 대소문자를 정확히 지켜야 함 (`/Volumes` ← 대문자 V). [GitHub Issue #1571](https://github.com/orbstack/orbstack/issues/1571)에서 해결 확인.

### 4-B. nodeAffinity

```yaml
# 배포 전 반드시 실행:
# kubectl get nodes -o wide
# OrbStack 노드명은 보통 "orbstack" 또는 "default"

nodeAffinity:
  required:
    nodeSelectorTerms:
      - matchExpressions:
          - key: kubernetes.io/hostname
            operator: In
            values:
              - orbstack    # ← 실제 노드명으로 교체 필수
```

### 4-C. Probe 설계

```yaml
# Immich Server (포트 2283)
# 교차검증: /api/server-info/ping은 DEPRECATED
#           현재 올바른 경로: /api/server/ping (응답: {"res":"pong"})

startupProbe:
  httpGet:
    path: /api/server/ping
    port: 2283
  periodSeconds: 5
  failureThreshold: 30              # 최대 150초 대기 (ML 모델 로딩)

readinessProbe:
  httpGet:
    path: /api/server/ping
    port: 2283
  periodSeconds: 5
  failureThreshold: 2

livenessProbe:
  httpGet:
    path: /api/server/ping
    port: 2283
  periodSeconds: 10
  failureThreshold: 3
```

> **교차검증 결과:** 기존 분석의 `/api/server-info/ping`은 **더 이상 유효하지 않음**.
> Immich 소스코드 `server/src/controllers/server.controller.ts` 확인:
> `@Controller('server')` + `@Get('ping')` + global prefix `api` → **`/api/server/ping`**

**SSD 분리 대응 원칙:**
- Pod probe로 SSD 상태를 감지하지 **않음** (SSD 없이 재시작해도 복구 불가)
- 별도 launchd 워치독 + AlertManager 규칙으로 SSD 상태 감시
- SSD 분리 시: 알림 → 수동 조치 (재연결 후 Pod 재시작)

---

## 5. 백업 전략

### 5-A. 3-2-1 현실 인정

```
실제 달성 구조: 2-1-1

  복사본 1: 외장 SSD 원본 (library/ + thumbs/ + encoded-video/)
  복사본 2: Cloudflare R2 (Restic encrypted)
  ─────────────────────────────────────────────
  미디어 1: 외장 SSD (단일 장애점)
  미디어 2: 클라우드 (R2)
  오프사이트: R2 ✓

  ⚠️ SSD 로컬 Restic repo는 동일 물리 디스크이므로
     별도 "미디어"로 계산하지 않음.
     SSD 고장 시 원본 + 로컬 Restic 동시 소실.
     R2가 유일한 보호막.
```

**로컬 Restic repo의 존재 이유:** R2보다 빠른 복원 속도 (네트워크 미사용). 전체 라이브러리 복원 시 R2에서 수시간~수일 걸릴 수 있으나, 로컬 Restic은 수분 내 가능. 단, SSD 고장 시에는 R2만 유효.

### 5-B. 백업 흐름

**방법: Restic CronJob에 initContainer로 pg_dump 포함 (race condition 방지)**

별도 CronJob 2개를 시간차로 돌리면 pg_dump가 늦어질 때 Restic이 불완전한 덤프를 백업하는 race condition이 발생할 수 있다. initContainer 패턴으로 순서를 보장한다.

```
매일 03:00 KST ── Restic backup CronJob ────────────────────────────

  initContainer: pg_dump
    └→ pg_dump -Fc immich > /backups/pgdump/immich.sql
       (Pod 내부 경로, 최근 7일 보존)
       ↓ 완료 후에만 main container 시작

  main container: restic backup
    └→ restic backup \
         /media/library \
         /backups/pgdump/immich.sql
       대상:
         - 로컬 repo: /backups/restic/ (속도 버퍼)
         - R2 repo: s3:immich-backup/ (오프사이트 보호)
       보존 정책:
         - keep-daily 7, keep-weekly 4, keep-monthly 6
       제외:
         - thumbs/ (재생성 가능)
         - encoded-video/ (재생성 가능)
         - upload/ (임시 파일)

  Volume Mounts (호스트 경로 → Pod 내부 경로):
    /Volumes/ukkiee/immich   → /media      (readOnly)
    /Volumes/ukkiee/backups  → /backups    (readWrite)
```

> **호스트 경로 vs Pod 경로:** K8s CronJob 매니페스트에는 hostPath로 `/Volumes/ukkiee/*`를 마운트하고,
> Pod 내부에서는 `/media`, `/backups` 등의 내부 경로를 사용한다. 문서에서 경로를 혼동하지 않도록 주의.

### 5-C. 복원 시나리오

| 시나리오 | 복원 소스 | 예상 시간 | 데이터 손실 |
|---------|----------|----------|-----------|
| 파일 실수 삭제 | 로컬 Restic | 수분 | 최대 24시간 |
| SSD 고장 | **R2 Restic** | 수시간~수일 | 최대 24시간 |
| DB 손상 | pgdump (외장 SSD) | 수분 | 최대 24시간 |
| DB + SSD 동시 고장 | pgdump in R2 Restic | 수시간 | 최대 24시간 |

---

## 6. SSD 모니터링 + 건강 관리

### 6-A. launchd 워치독 (macOS)

```bash
#!/bin/bash
# ~/Scripts/check-immich-ssd.sh

SSD_PATH="/Volumes/ukkiee"
WEBHOOK_TOKEN="TVBPl838SfjRSTVZpBqtBUByopzFygUf"

notify() {
  curl -s -X POST https://api.getmoshi.app/api/webhook \
    -H "Content-Type: application/json" \
    -d "{\"token\": \"$WEBHOOK_TOKEN\", \"title\": \"$1\", \"message\": \"$2\"}"
}

# 1. 마운트 상태 확인
if [ ! -d "$SSD_PATH/immich" ]; then
  notify "SSD 분리 감지" "ukkiee가 마운트 해제됨. 즉시 확인 필요."
  exit 1
fi

# 2. SMART 건강 확인 (TB4 연결 시)
if command -v smartctl &>/dev/null; then
  DISK=$(diskutil info "$SSD_PATH" 2>/dev/null | grep "Device Node" | awk '{print $NF}')
  if [ -n "$DISK" ]; then
    HEALTH=$(sudo smartctl -H "$DISK" 2>/dev/null | grep -c "PASSED")
    if [ "$HEALTH" -eq 0 ]; then
      notify "SSD 건강 이상" "ukkiee SMART 검사 실패. 즉시 백업 확인 후 교체 검토."
    fi

    # 3. 수명 소모율 확인
    PCT_USED=$(sudo smartctl -A "$DISK" 2>/dev/null | grep "Percentage Used" | awk '{print $NF}' | tr -d '%')
    if [ -n "$PCT_USED" ] && [ "$PCT_USED" -gt 80 ]; then
      notify "SSD 수명 경고" "ukkiee 수명 ${PCT_USED}% 소모. 교체 계획 필요."
    fi
  fi
fi

# 3. 용량 확인
USAGE=$(df "$SSD_PATH" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
if [ -n "$USAGE" ] && [ "$USAGE" -gt 85 ]; then
  notify "SSD 용량 경고" "ukkiee 사용률 ${USAGE}%. Restic prune 또는 용량 확장 필요."
fi
```

```xml
<!-- ~/Library/LaunchAgents/dev.homelab.check-ssd.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.homelab.check-ssd</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Users/ukyi/Scripts/check-immich-ssd.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
```

### 6-B. Phase 1 이후 AlertManager 규칙 (추가)

Phase 1 (Prometheus) 완료 후 아래 알림 규칙 추가:

```yaml
# PVC 용량 부족 (Immich 미디어)
- alert: ImmichStorageHigh
  expr: |
    kubelet_volume_stats_used_bytes{persistentvolumeclaim="immich-media-pvc"}
    /
    kubelet_volume_stats_capacity_bytes{persistentvolumeclaim="immich-media-pvc"}
    > 0.85
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Immich 미디어 스토리지 85% 초과"

# Immich Pod CrashLoop (SSD 분리 가능성)
- alert: ImmichCrashLoop
  expr: |
    increase(kube_pod_container_status_restarts_total{
      namespace="immich", container="immich-server"
    }[10m]) > 3
  labels:
    severity: critical
  annotations:
    summary: "Immich 서버 반복 재시작 — SSD 분리 가능성 확인"
```

---

## 7. 리소스 예산

### 7-A. Immich 스택 리소스

| 컴포넌트 | CPU Request | CPU Limit | Memory Request | Memory Limit | Storage |
|----------|:-----------:|:---------:|:--------------:|:------------:|--------:|
| Immich Server | 250m | 2000m | 512Mi | 2Gi | - |
| Immich ML | 500m | 4000m | 1Gi | 4Gi | 5Gi (ML 캐시) |
| PostgreSQL | 250m | 1000m | 512Mi | 2Gi | 10Gi |
| Redis | 100m | 500m | 256Mi | 512Mi | 1Gi |
| **Immich 합계** | **1,100m** | - | **2,304Mi (~2.3Gi)** | - | **16Gi (내장)** |

> Immich 공식 요구사항: 최소 RAM 6GB, 권장 8GB (전체 스택).
> Mac Mini M4 (16Gi) 기준 ML 추론 포함 시 충분.

### 7-B. 전체 리소스 누적 추이 (업데이트)

| 시점 | CPU Request | Memory Request | 내장 Storage | 외장 Storage | M4 사용률 |
|------|:-----------:|:--------------:|:------------:|:------------:|:---------:|
| 현재 | ~800m | ~0.9Gi | 6Gi | - | CPU 8%, Mem 6% |
| +Phase 1 | 1,400m | ~2.1Gi | 29Gi | - | CPU 14%, Mem 13% |
| +Phase 3 | ~1,650m | ~2.6Gi | 39Gi | - | CPU 17%, Mem 16% |
| +Phase 4 | ~2,175m | ~3.4Gi | 40Gi | - | CPU 22%, Mem 21% |
| **+Immich** | **~3,275m** | **~5.7Gi** | **56Gi** | **~1,750Gi** | **CPU 33%, Mem 36%** |
| +Phase 6 | ~3,375m | ~5.9Gi | 57Gi | ~1,750Gi | CPU 34%, Mem 37% |

> ML 추론은 burst 워크로드 (사진 업로드 시에만 CPU 집중 사용).
> 평상시 idle: CPU ~15%, Memory ~30% 예상. **리소스 여유 충분.**

---

## 8. 구현 체크리스트

### Phase S-1: 하드웨어 준비 ✅

- [x] NVMe 인클로저: TB4 인클로저 `TBU405` 사용 중
- [x] NVMe SSD: SK hynix Gold P31 2TB (`SHGP31-2000GM`)
- [x] 인클로저에 SSD 장착 완료
- [x] Mac Mini M4 후면 TB4 포트 2에 연결 (40 Gb/s 확인)
- [x] APFS 포맷 완료 (볼륨명: `ukkiee`, `/Volumes/ukkiee`)
- [x] 디렉토리 구조 생성 (`immich/`, `backups/pgdump/`, `backups/restic/`)

### Phase S-2: macOS 설정 ✅

- [x] `pmset -a disksleep 0, sleep 0, displaysleep 0`
- [x] SMART 상태: Verified
- [x] TRIM 지원: Yes
- [x] Full Disk Access: Ghostty + OrbStack 추가
- [x] `diskutil enableOwnership /Volumes/ukkiee`
- [x] `mdutil -i off /Volumes/ukkiee` — Spotlight 비활성화
- [x] `tmutil addexclusion /Volumes/ukkiee` — Time Machine 제외
- [x] `brew install smartmontools`

### Phase S-3: OrbStack 경로 검증 ✅

- [x] 노드명 확인: `orbstack`
- [x] Docker bind mount 읽기/쓰기 테스트 — PASS
- [x] K8s hostPath bind mount 읽기/쓰기 테스트 — PASS (2.8 GB/s)

### Phase S-4: K8s 리소스 배포 ✅

- [x] `immich` namespace 생성
- [x] DB Secret 생성 (비밀번호 매니저에 저장 필요)
- [x] PV 4개 생성 (media, backup, postgres, ml-cache)
- [x] PVC 4개 Bound 확인
- [x] PostgreSQL 배포 — `pg_isready` PASS
- [x] Redis 배포 — `redis-cli ping` PONG
- [x] Immich Server 배포 — `/api/server/ping` → `{"res":"pong"}`
- [x] Immich ML 배포 — `/ping` → `pong`
- [x] IngressRoute 배포 (`photos.ukkiee.dev`, web + websecure)
- [x] Cloudflare Tunnel Public Hostname 추가
- [x] AdGuard DNS 캐시 클리어
- [x] 웹 UI 접속 확인 (`photos.ukkiee.dev`)
- [x] Admin 계정 생성
- [x] 사진 업로드 + 썸네일 생성 + ML 처리 정상 확인
- [ ] NetworkPolicy 추가 (Phase S-4f, 아래 별도 체크리스트)

### Phase S-4f: NetworkPolicy (미진행)

- [ ] `immich` namespace default deny (ingress + egress)
- [ ] Immich Server → PostgreSQL (egress)
- [ ] Immich Server → Redis (egress)
- [ ] Immich Server → Immich ML (egress, port 3003)
- [ ] Immich Server → DNS (egress, port 53)
- [ ] Immich ML → DNS (egress, port 53)
- [ ] Immich ML → internet:443 (egress) — 모델 다운로드
- [ ] Restic CronJob → internet:443 (egress) — R2 업로드
- [ ] Restic CronJob → PostgreSQL (egress) — pg_dump
- [ ] Traefik → Immich Server (ingress, port 2283)

### Phase S-5: 백업 자동화 (미진행)

- [ ] Restic 백업 CronJob 배포 (03:00 KST, initContainer로 pg_dump 포함)
- [ ] 수동 Restic 백업 1회 실행 + 복원 테스트
- [ ] R2 버킷 생성 + Restic 원격 repo 초기화
- [ ] `backup.sh` 업데이트 (Immich PVC 상태 확인 추가)

### Phase S-6: 모니터링 + 검증 (미진행)

- [ ] launchd 워치독 스크립트 작성 + 등록
- [ ] SSD 분리 시뮬레이션 → 알림 수신 확인
- [ ] Phase 1 완료 시: AlertManager 규칙 추가
- [ ] 모바일 앱 자동 백업 연결 테스트

---

## 9. 의존성 + 타이밍

### Phase S 의존성 맵

```
Phase S-1~S-3 (하드웨어 + macOS + OrbStack 검증)
  └→ Phase S-4 (K8s 배포) ── Phase 3-B PostgreSQL과 병렬 가능
       └→ Phase S-5 (백업 자동화)
            └→ Phase S-6 (모니터링)

Phase 1 (Prometheus) ──→ Phase S-6에서 AlertManager 규칙 추가
```

### 기존 Phase와의 관계

| Phase | 관계 |
|-------|------|
| Phase 1 (Monitoring) | Phase S-6에서 AlertManager 규칙 추가. 병렬 가능. |
| Phase 3-B (PostgreSQL) | Immich PostgreSQL은 **반드시 별도 인스턴스**. Immich는 벡터 확장(pgvecto.rs/VectorChord)이 필수이며, 전용 이미지(`ghcr.io/immich-app/postgres`)를 사용한다. API 서버 PostgreSQL과 공유 불가. |
| Phase 4 (Infisical) | Immich 시크릿(DB 접속, API 키 등)도 Infisical에 등록. |
| Phase 6 (공개 서비스) | `photos.ukkiee.dev`가 첫 공개 서비스가 되면 Phase 6 동시 트리거. 초기에는 Tailscale-only 권장. |

---

## 10. 교차검증 결과 추적표

| # | 검증 항목 | 결과 | 비고 |
|---|----------|:---:|------|
| 1 | OrbStack `/Volumes/` bind mount 동작 | **검증됨** | Issue #1571 해결, 대소문자 주의 |
| 2 | VirtioFS 성능 (사진 I/O) | **충분** | 75-95% native, 순차 I/O 중심 |
| 3 | 내장 SSD 용량 (512GB) | **넉넉** | Immich 추가 ~9Gi, 총 ~115Gi, 여유 ~350Gi |
| 4 | Health check 경로 | **수정됨** | ~~`/api/server-info/ping`~~ → `/api/server/ping` |
| 5 | 썸네일 용량 | **재산정** | 원본의 10-20% (공식), 10만 장 기준 50-100Gi |
| 6 | PostgreSQL 위치 | **내장 필수** | 공식 요구: "must be on local SSD, never network share" |
| 7 | TB4 SMART/TRIM | **실기기 확인** | SK hynix P31 + TBU405: SMART Verified, TRIM Yes |
| 8 | 3-2-1 백업 현실 | **수정** | 실질 2-1-1, R2가 유일한 보호막으로 명시 |
| 9 | pg_dump 선행 | **반영** | Restic 10분 전 스케줄 (02:50 KST) |
| 10 | nodeAffinity hostname | **배포 시 확인** | `kubectl get nodes -o wide` 선행 필수 |
| 11 | Redis 분리 | **반영** | Immich/Infisical Redis 별도 인스턴스 |
| 12 | 디스크 절전 | **설정 완료** | `pmset -a disksleep 0` 확인됨 |
| 13 | Immich 기본 포트 | **확인** | 2283 (Server), 3003 (ML, 내부 전용) |
| 14 | ML 모델 캐시 크기 | **확인** | CLIP ~600MB + 얼굴 ~1GB = ~2GB, 여유 포함 3Gi |

---

## 11. 기존 분석 이슈 해결 상태

### CRITICAL

| # | 이슈 | 해결 상태 |
|---|------|:---:|
| 1 | OrbStack+macOS와 SSD 관리 비호환 | **해결** — macOS 네이티브(launchd, APFS, diskutil)로 전체 대체 |
| 2 | 3-2-1 백업 오해 | **해결** — 실질 2-1-1로 정정, R2가 유일한 보호막 명시 |
| 3 | PV 용량 계획 오류 | **해결** — immich 1,400Gi + backups 350Gi + 여유 50Gi |

### IMPORTANT

| # | 이슈 | 해결 상태 |
|---|------|:---:|
| 4 | Probe 설계 불완전 | **해결** — HTTP probe + startupProbe + 경로 교정 (`/api/server/ping`) |
| 5 | pg_dump 선행 누락 | **해결** — 02:50 KST CronJob, Restic 10분 전 |
| 6 | macOS 디스크 절전 | **해결** — `pmset -a disksleep 0` |
| 7 | SMART over USB 제한 | **해결** — TB4 인클로저 필수 선택으로 NVMe SMART 네이티브 지원 |
| 8 | nodeAffinity hostname | **배포 시 검증** — `kubectl get nodes` 선행 체크리스트 포함 |

### MINOR

| # | 이슈 | 해결 상태 |
|---|------|:---:|
| 9 | Redis 분리 | **반영** — Immich/Infisical Redis 별도 인스턴스 명시 |
| 10 | Phase 6 트리거 시점 | **명시** — 초기 Tailscale-only, 공개 전환 시 Phase 6 트리거 |
| 11 | 용어 통일 | **해결** — Vaultwarden 용어로 통일 (Phase 4 이후 Infisical) |

---

## 참고 자료

- [OrbStack Volumes & Mounts](https://docs.orbstack.dev/docker/file-sharing)
- [OrbStack Fast Filesystem](https://orbstack.dev/blog/fast-filesystem)
- [OrbStack External Drive Issue #1571](https://github.com/orbstack/orbstack/issues/1571)
- [TRIM and SMART on External Drives (macOS)](https://eclecticlight.co/2024/04/09/which-external-drives-have-trim-and-smart-support/)
- [Immich Official Docs](https://immich.app/docs)
- [Immich Custom Locations Guide](https://docs.immich.app/guides/custom-locations/)
