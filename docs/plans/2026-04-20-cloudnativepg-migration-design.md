# PostgreSQL 관리 CloudNativePG 마이그레이션 설계

> **작성일**: 2026-04-20
> **버전**: **v0.4** (design-review v0.3 리뷰 반영)
> **상태**: 재확정 · implementation plan 동기화 필요 (plan.md Phase 0/1/2/8 갱신 예정)
> **관련 결정**: Bitnami PostgreSQL Helm (실측 v18.3.0 · Git drift) → CloudNativePG operator 전환
> **선행 논의**: 브레인스토밍 A/B/C 비교 → C 채택 · v0.1 리뷰 23건 · v0.2 Q13–15 확정 · v0.3 Q1–15 확정 · **v0.4 심층 리뷰 13건 + 리뷰 누락 4건 반영**

## 변경 이력

### v0.3 → v0.4 (2026-04-20 · 본 리비전)

**심층 리뷰 (`docs/plans/2026-04-20-cloudnativepg-migration-design-review.md`) 반영 + 리뷰 누락분 보완**.

| 카테고리 | 반영 항목 | 위치 |
|---|---|---|
| **Critical** | C1 (현재 상태 팩트체크 + Bitnami drift) | §1.1 · Phase 0 I-0 · Phase 8 재설계 |
| | C2 (kubeseal in-cluster Service 직접 호출) | §D10 |
| | C3 (ArgoCD Kustomize+Helm 렌더 전략 D-5) | §12 Phase 0 Decision · Phase 1.0 · §A.1/§A.2 주석 |
| **High** | H1 (`mode: reference` semantics 명확화 — 동일 계정 공유 확정) | §D7 · §D9 · §6.1 |
| | H2 (Database CRD GA 검증 I-2a) | §12 Phase 0 Investigation |
| | H3 (NetworkPolicy CIDR 가능 · 정밀도 낮음 정정) | §D14 · §9 |
| | H4 (PITR Git PR 3개 단계 절차) | §8.2 |
| | H5 (`backupOwnerReference` `self` → `cluster`) | §D5 · §A.7 |
| | H6 (Renovate packageRules auto-merge 금지) | §D3 |
| **Medium** | M1 (`imageName` placeholder 표기 명시) | §D3 · §A.5 |
| | M2 (AppProject **3축** 확장 — whitelist+sourceRepos+destinations) | §D11 · Phase 2.0 |
| | M3 (Postgres GUC shared_buffers·work_mem·max_connections pin) | §D15 |
| | M4-M7 | §D14 주석 · §8.4 I-7 · Renovate 정책 |
| **리뷰 누락 보완** | A1 — Phase 8 Bitnami 폐기 절차 **전면 재설계** (`helm uninstall` 선행) | §12 Phase 8 |
| | I-0 팩트체크 결과 박제 (Bitnami v18.3.0 Git drift 확인) | §1.1 · §12 Phase 0 |
| | R15-R18 리스크 신규 | §13 |

### v0.1 → v0.2 (2026-04-20)

공식 CNPG 문서 교차검증 기반 **구조적 3건 + High/Medium 다수 반영**. 상세 diff는 §Appendix D.

- **C1 Role/Secret 관리 방식 전환**: `Database` CRD는 DB 객체만 생성하며 role/password/secret은 **사용자가 SealedSecret 먼저 생성 → `Cluster.spec.managed.roles[].passwordSecret` 참조** 방식으로 전환. per-DB 자동 secret 가정 폐기.
- **C2 메트릭 이름 교정**: 4개 알람 규칙을 실제 exporter 이름 기준으로 재작성. 일부는 v1.26에서 deprecated → 플러그인 메트릭 이관 예정.
- **C3 Backup 방식 Plugin 전환**: `spec.backup.barmanObjectStore` (in-tree) → **plugin-barman-cloud + 별도 `ObjectStore` CR**. 이유: in-tree가 v1.26 deprecated, **v1.30에서 제거 예정**. 홈랩에 **cert-manager 신규 설치가 Phase 1 필수 전제**로 승격.
- **H10 모니터링**: PodMonitor 비활성화, Alloy 직접 scrape로 재설계
- **H2 Cron TZ 통일**, **H3 NetworkPolicy 한계 명시**, **H6 WAL PVC 통합**, **H7 리소스 limit 상향** 등 수용
- **M2 SealedSecret scope 재평가**: cluster-wide → namespace-scoped + 템플릿 seal 자동화로 재설계
- **Phase 0 재구성**: 기존 체크리스트 → `Decision / Investigation / Action` 3-카테고리 blocking gate

---

## 0. TL;DR

- **무엇**: Bitnami PostgreSQL Helm (실측 v18.3.0, `helm install` 직접 · **Git drift**) → **CloudNativePG operator + barman-cloud 플러그인** 전환.
- **왜**: 모노레포 "A 생성 / B 참조" 및 "A·B 각자 DB" 요구사항을 `Database` CRD + `managed.roles` 선언으로 커버. 수동 pg_dump CronJob은 플러그인 Barman Cloud로 대체하며 PITR 표준화.
- **어떻게**: 3-stack 설치 (cert-manager → CNPG operator → barman-cloud plugin) → 프로젝트별 전용 `Cluster` + `ObjectStore` → 서비스별 role SealedSecret + Database CRD → 앱 Deployment가 user-created secret 참조.
- **영향 범위**: 현재 공유 postgres 실사용 앱 0개 → **데이터 마이그레이션 부담 없음**. Phase 8 에서 `helm uninstall postgresql -n apps` 로 Bitnami 제거 (v0.4 A1).
- **새 의존**: cert-manager 설치 필요 (plugin 구성 요소가 mTLS gRPC 인증서 요구).
- **예상 기간**: **12–15일** (v0.4 기준 · Phase 0 확장 조사 + Phase 1.0 argocd-cm 분기 + Phase 8 helm uninstall 정리 반영)
- **롤백 리스크**: 낮음. Phase 5 이전까지 Bitnami 병렬 유지.
- **v0.4 신규 블로커**: Phase 0 **D-5** (ArgoCD Kustomize+Helm 렌더 전략), **I-0a** (Bitnami drift 대응 방침), **I-2a** (Database CRD stability), **I-7** (R2 Object Lock 지원) — 4개 결정·조사 완료 후 Phase 1 진입.

---

## 1. 배경 & 현재 상태

### 1.1 현재 PostgreSQL 구성 (v0.4 실측 갱신)

| 항목 | 현재 값 |
|---|---|
| **배포 방식** | **Bitnami `postgresql-18.5.15` Helm chart** (app v18.3.0) — **`helm install` 직접 배포, Git 매니페스트 drift** |
| **ArgoCD 관리 범위** | Application `postgresql`은 `manifests/apps/postgresql/` 내 **backup 리소스 3개만** 관리 (StatefulSet/Service/PVC는 관리 밖) |
| 네임스페이스 | `apps` |
| DB 개수 | 1개 (`api`) · hard-coded |
| 유저 개수 | 1개 (`api`) |
| 스토리지 (`data-postgresql-0`) | 5Gi local-path PVC (25d 전 바인딩) |
| 리소스 | request 50m/48Mi · limit 300m/96Mi |
| 시크릿 | `postgresql-auth` (SealedSecret, 25d) |
| 메트릭 | exporter sidecar · `postgresql-metrics` Service 9187/TCP (2d 3h 전 수동 추가 — **drift 추정 리소스**) |
| 백업 | 일 03:00 KST pg_dump CronJob → R2 + 외장 SSD 3계층 (daily 7d / weekly 28d / monthly 180d) |
| 백업 PVC | `postgresql-backups-ssd` 20Gi (external-ssd StorageClass, 41h 전 바인딩) |

> **⚠️ Git drift 박제 (Phase 0 I-0 결과 반영, 2026-04-20)**
>
> `helm list -n apps` 가 `postgresql-18.5.15` (deployed) 를 반환하며 StatefulSet 레이블 `meta.helm.sh/release-name=postgresql` 확인. 그러나 `git log --all -- manifests/apps/postgresql/ | grep -i statefulset` 는 0건 — 클러스터에 살아 있는 Bitnami StatefulSet·Service·PVC 가 **Git 에 박제되어 있지 않다**. 과거 어느 시점에 매니페스트가 정리되었거나, 최초부터 `helm install` 로 직접 배포된 상태. 이 drift 는 **§12 Phase 8 Bitnami 폐기 절차를 전면 재설계**한다 (단순 `ArgoCD Application 삭제 → cascade` 로는 StatefulSet 제거 불가 → `helm uninstall` 선행 필요).

### 1.2 실사용 현황

- **실사용 앱: 0개** (재확인) — Bitnami PostgreSQL 18 이 클러스터에 살아 있으나 `postgresql-auth` secret 을 참조하는 앱 없음. backup CronJob 만이 유일한 참조자.
- 공유 postgres 는 "프로비저닝만 되고 아무도 쓰지 않는" 상태 → 재설계 골든 타이밍. 데이터 손실 리스크 실질 0.
- **Postgres major 버전 주의**: 실제 클러스터 버전 **18.3.0**, 본 설계 마이그레이션 타겟 **16 (LTS, EOL 2028-11)**. 실사용 0개이므로 데이터 이관 불필요 — 단순 폐기·신규 설치. 버전 선택 근거는 §D4.

### 1.3 자동화 파이프라인 현황

- `.github/actions/setup-app/action.yml` (882줄 composite)
- 앱 타입: static / worker / 기타
- 모노레포 레이아웃: `manifests/apps/<app>/{common,services/<svc>}/`
- **DB 관련 훅 없음**.

### 1.4 요구사항

1. 모노레포 프로젝트 `P` 내부에 서비스 A·B가 있을 때
   - **시나리오-1 (공유 DB)**: A가 schema 소유, B가 동일 DB 참조
   - **시나리오-2 (분리 DB)**: A·B 각자 독립 DB 사용
2. 신규 프로젝트 setup-app 스캐폴딩에서 DB 옵션 선언 한 줄로 on/off
3. 기존 Bitnami 실사용자 없음 → 단순 폐기

---

## 2. 목표 · 비목표

### 2.1 목표

- **G1**. cert-manager 도입 (plugin 전제조건)
- **G2**. CNPG operator + barman-cloud plugin 선언형 배포
- **G3**. 모노레포 프로젝트별 독립 `Cluster` 인스턴스
- **G4**. `Cluster.spec.managed.roles[]` + user-created SealedSecret으로 role·password 관리
- **G5**. `Database` CRD 기반 DB 생성 (owner는 managed.roles가 먼저 생성한 role)
- **G6**. `ObjectStore` CR + R2 백업 + PITR 표준화
- **G7**. 앱 연결 정보 주입 규약 표준화
- **G8**. setup-app composite action 확장
- **G9**. Bitnami 차트 안전 폐기
- **G10**. 모니터링·알람 통합 (실존 메트릭 기반)
- **G11**. PITR 리허설 Runbook 작성·드라이런 성공

### 2.2 비목표

- **N1**. HA (streaming replication · multi-instance failover)
- **N2**. 외부 관리형 DB
- **N3**. Connection pooler 초기 도입
- **N4**. 논리 복제
- **N5**. Postgres minor 자동 업그레이드 — Renovate packageRules 별도 턴
- **N6**. 세밀한 role 권한 관리 — Phase 8 이후

---

## 3. 대안 비교 요약

| 기준 | A. Bitnami 확장 | B. 프로젝트별 Bitnami | **C. CloudNativePG + Plugin (채택)** |
|---|---|---|---|
| DB/user 프로비저닝 | 수동 SQL | 인스턴스마다 hard-code | 선언형 (`managed.roles` + `Database`) |
| 백업 | 직접 CronJob | 인스턴스마다 CronJob | Plugin + `ObjectStore` CR (PITR 포함) |
| 모노레포 secret 접근 | cross-ns 복제 필요 | co-located | co-located |
| 격리 | 약함 | 강함 | 강함 (per-project Cluster) |
| 메모리 오버헤드 | 적음 | 인스턴스×300Mi | cert-manager 100Mi + operator 200Mi + plugin 100Mi + 인스턴스×400Mi |
| 학습 곡선 | 없음 | 낮음 | 중-상 (plugin 포함) |
| 장기 표준화 | 낮음 | 낮음 | 높음 |

**결정**: C. 이유는 모노레포 요구사항 1:1 매칭, 백업·PITR 표준화, 장기 운영 이득. in-tree barman 대신 plugin 채택 이유는 6-12개월 내 v1.30 제거 예정 → 이중 작업 회피.

---

## 4. 솔루션 개요

### 4.1 구성 요소 3계층

```
[Layer 1] cert-manager         ← 플러그인의 gRPC mTLS 인증서 발급
[Layer 2] CNPG operator        ← Cluster·Database·Backup 등 핵심 CRD 관리
[Layer 3] plugin-barman-cloud  ← ObjectStore CR + 백업 실행 에이전트
```

### 4.2 아키텍처 (v0.2)

```
┌─────────────────────────────────────────────────────────────────┐
│ ArgoCD (App-of-Apps)                                            │
│                                                                 │
│ infra/   ← sync wave -1                                         │
│   ├─ cert-manager        (신규)                                 │
│   ├─ cnpg-operator       (신규)                                 │
│   └─ cnpg-barman-plugin  (신규)                                 │
│                                                                 │
│ apps/    ← sync wave 0                                          │
│   └─ <project>/                                                 │
│        manifests/apps/<project>/                                │
│        ├─ common/                                               │
│        │   ├─ namespace.yaml                                    │
│        │   ├─ r2-backup.sealed.yaml      ← R2 자격증명           │
│        │   ├─ role-secrets.sealed.yaml   ← role password들      │
│        │   ├─ cluster.yaml               ← managed.roles 포함   │
│        │   ├─ objectstore.yaml           ← Plugin ObjectStore CR│
│        │   ├─ scheduled-backup.yaml                             │
│        │   └─ database-shared.yaml       (시나리오-1)           │
│        └─ services/                                             │
│             ├─ api/                                             │
│             │   ├─ database.yaml         (시나리오-2)           │
│             │   └─ deployment.yaml       ← envFrom + env 조합   │
│             └─ scraper/                                         │
└─────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│ Namespace: <project>                                            │
│                                                                 │
│  [User-provided SealedSecrets]                                  │
│      <project>-pg-api-credentials        (basic-auth)           │
│      <project>-pg-scraper-credentials    (basic-auth)           │
│      r2-pg-backup                        (R2 access keys)       │
│                                                                 │
│  [Cluster CR]                                                   │
│    spec.managed.roles:                                          │
│      - api      → passwordSecret: <...-api-credentials>         │
│      - scraper  → passwordSecret: <...-scraper-credentials>     │
│    spec.plugins: [barman-cloud → ObjectStore <project>-backup]  │
│                                                                 │
│  [Database CR]  name=api · owner=api   (role 선행 존재 필수)    │
│                                                                 │
│  [Deployment]                                                   │
│    env:                                                         │
│      POSTGRES_HOST=<project>-pg-rw        (static)              │
│      POSTGRES_DB=api                      (static)              │
│      POSTGRES_USER=api                    (static)              │
│      POSTGRES_PASSWORD=fromSecret         (user-created)        │
│                                                                 │
│  ObjectStore ─── Plugin Agent ─── WAL + base ─▶ R2 (Barman)    │
└─────────────────────────────────────────────────────────────────┘
```

---

## 5. 핵심 설계 결정

### D1. 인스턴스 전략 — **프로젝트별 전용 Cluster**

(v0.1 동일) 프로젝트 namespace에 Cluster 1개 배치. Database CRD·role Secret도 같은 namespace로 co-location하여 cross-namespace secret 복제 회피.

### D2. Operator 네임스페이스 — **`cnpg-system`** · **`cert-manager`** · `cnpg-system` (plugin)

- `cert-manager` (신규 infra Application)
- `cnpg-system` — operator와 plugin-barman-cloud 동일 namespace (plugin 공식 설치 가이드)
- 각 Application이 `CreateNamespace=true` 로 자동 생성

### D3. Cluster 기본 스펙 (v0.4 수정 · M1+H5+H6 반영)

```yaml
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:<PIN_IN_PHASE_0>   # M1: placeholder 명시 — Phase 0 I-2에서 정확한 태그(예: 16.6-1) 확정
  primaryUpdateStrategy: unsupervised   # 단일 인스턴스 minor 업그레이드 무인 재시작 허용 — Renovate auto-merge 금지 전제 (H6)
  storage:
    size: 5Gi                           # D 시나리오 확정 (local-path resize 미지원) → 넉넉한 default
    storageClass: local-path            # K3s 기본
  resources:
    requests: { cpu: 100m, memory: 384Mi }
    limits:   { cpu: 1000m, memory: 1Gi }  # H7 반영: initdb·base backup peak 대비
  monitoring:
    enablePodMonitor: false             # H10 반영: Alloy 직접 scrape
  # v0.4 H6 반영: unsupervised + Renovate auto-merge 조합 시 임의 시각 자동 다운타임.
  # 대응은 § Renovate 정책 (아래) 에서 PR-only 강제.
```

**변경 사항**:
- `walStorage` 제거 → `storage.size` 5Gi 로 통합 (H6: 단일 노드 · local-path 환경에선 I/O 격리 이득 없음)
- `limits.memory` 512Mi → 1Gi (H7)
- `enablePodMonitor: false` (H10: Alloy는 PodMonitor 미지원)
- `primaryUpdateStrategy: unsupervised` 유지 + **H6 반영 Renovate 정책 필수 병행** (§12 Phase 7 M10 에 명시)
- **v0.4 M1 반영**: `imageName` 값을 `16.x` placeholder 에서 `<PIN_IN_PHASE_0>` 명시적 토큰으로 전환 — copy-paste 사고 방지.

**Renovate 정책 (v0.4 H6 신규)**:

```jsonc
// .github/renovate.json5 의 packageRules 에 추가
{
  "groupName": "cnpg-stack",
  "matchPackageNames": [
    "cloudnative-pg",
    "plugin-barman-cloud",
    "ghcr.io/cloudnative-pg/postgresql"
  ],
  "matchUpdateTypes": ["patch", "minor", "major"],
  "automerge": false,                    // 수동 리뷰 강제
  "dependencyDashboardApproval": true,   // dashboard 에서 명시 승인 후에만 PR 개방
  "schedule": ["before 9am on monday"]   // 운영자 작업 창 내로 제한
}
```

근거: Postgres 는 minor 업그레이드조차 primary pod 재시작 → 단일 인스턴스 환경에서 다운타임. `unsupervised` 는 "운영자가 의도한 변경에 대한 무인 재시작 허용" 으로 제한, 자동 PR 흐름에서는 항상 운영자 승인 게이트 필수.

**업그레이드 메서드 (v0.4 리뷰 M1 신규)**:

CNPG 는 operator image 업그레이드 시 두 가지 메서드 — **inplace** (같은 pod 내 restart, 빠름·다운타임 수초-30초) vs **rolling** (새 pod 기동 후 primary promote, 수분·단일 인스턴스는 실효 다운타임 inplace 와 유사). 단일 인스턴스에서 rolling 의 이득은 거의 없으므로 `inPlaceUpdates: true` (또는 chart values 의 동등 키) 로 명시 pin.

```yaml
# Cluster.spec 또는 operator chart values
spec:
  # CNPG 1.26+: inPlaceUpdates 필드 또는 annotation
  inPlaceUpdates: true
```

**다운타임 SLO**:
- **Postgres minor upgrade** (예: 16.6 → 16.7): 30초 – 2분 (pod restart · DB shutdown checkpoint 포함)
- **Operator upgrade**: ~30초 (operator pod 재시작은 DB pod 영향 없음)
- **Postgres major upgrade** (16 → 17 — §16 out-of-scope, 향후 계획 시): 수분-수십분 (pg_upgrade 또는 logical dump/restore)

Phase 9 Runbook `cnpg-upgrade.md` 에 운영자 사전 공지 절차 (예: 1시간 전 maintenance window 공지) 포함.

**Backup owner reference 정책 (v0.4 H5 반영)**:

§D5 ScheduledBackup 블록의 `backupOwnerReference` 선택:

```yaml
# 기본값 채택 (v0.4 확정): 'cluster'
# - ScheduledBackup 삭제/재생성 시 기존 Backup CR 이력 보존
# - Cluster 삭제 시에만 cascade GC — 이때는 어차피 cluster 자체를 접음
# - audit trail / Grafana 최근 backup 타임스탬프 패널 유지
spec:
  backupOwnerReference: cluster          # v0.3 'self' → v0.4 'cluster' 로 전환
```

Trade-off 요약:

| 값 | Backup CR 수명 | 장점 | 단점 |
|---|---|---|---|
| `self` (v0.3 제안) | ScheduledBackup 삭제 시 cascade 삭제 | 정리 자동, k8s etcd 공간 절약 | **이력 손실** — spec 변경 시 모든 Backup CR 증발 |
| `cluster` (**v0.4 채택**) | Cluster 삭제 시 cascade | 이력 보존 · 운영 관찰성 | Backup CR 누적 (작음, 홈랩 scale 에선 무시 가능) |
| `none` | 수동 관리 | 완전 분리 | 관리 부담 |

R2 객체 자체는 `retentionPolicy: 14d` 로 독립 정리되므로 CR 수명과 별개.

### D4. Postgres 버전 — **16** (LTS 고정)

(v0.1 동일) Postgres 16 · EOL 2028-11 · CNPG 공식 이미지 태그 Phase 0에서 pin.

### D5. 백업 & PITR — **Plugin 방식** (v0.2 전면 개편)

**의존성 체인**: cert-manager → plugin-barman-cloud install → ObjectStore CR → Cluster.spec.plugins 참조.

**ObjectStore CR** (namespace 내):

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: <project>-backup
  namespace: <project>
spec:
  configuration:
    destinationPath: s3://homelab-db-backups/<project>
    endpointURL: https://<ACCOUNT_ID>.r2.cloudflarestorage.com
    s3Credentials:
      accessKeyId:     { name: r2-pg-backup, key: ACCESS_KEY_ID }
      secretAccessKey: { name: r2-pg-backup, key: SECRET_ACCESS_KEY }
    wal:  { compression: gzip }
    data: { compression: gzip }
  retentionPolicy: "14d"
```

**Cluster 내 plugin 참조**:

```yaml
spec:
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: <project>-backup
        serverName: <project>-pg
```

**ScheduledBackup** (H2 반영 · UTC 기준):

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
spec:
  schedule: "0 0 18 * * *"            # UTC 18:00 = KST 03:00
  cluster: { name: <project>-pg }
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  backupOwnerReference: cluster       # v0.4 H5 반영: Backup CR audit trail 보존 위해 'self' → 'cluster' 전환
```

**R2 버킷 구조**: 단일 버킷 `homelab-db-backups` + 프로젝트별 prefix.

**제거 리스크 완화**: v1.26 → v1.30 사이 여유 있게 plugin 전환, in-tree 경로는 사용하지 않음.

### D6. Role 관리 & Database CRD — **v0.2 전면 개편**

**원칙**: role·password·secret은 사용자가 먼저 SealedSecret으로 제공, Database CRD는 DB 객체만.

**Step 1**: User가 role password SealedSecret 미리 생성

```yaml
apiVersion: v1
kind: Secret
type: kubernetes.io/basic-auth
metadata:
  name: <project>-pg-api-credentials
  namespace: <project>
  labels:
    cnpg.io/reload: "true"            # 패스워드 변경 자동 반영
stringData:
  username: api
  password: <strong-generated>
```

SealedSecret으로 seal 후 git commit.

**Step 2**: Cluster.spec.managed.roles로 role 선언

```yaml
spec:
  managed:
    roles:
      - name: api
        ensure: present
        login: true
        passwordSecret:
          name: <project>-pg-api-credentials
      - name: scraper
        ensure: present
        login: true
        passwordSecret:
          name: <project>-pg-scraper-credentials
```

**Step 3**: Database CRD로 DB 생성 (owner는 managed.roles가 먼저 생성한 role)

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: api
  namespace: <project>
spec:
  cluster: { name: <project>-pg }
  name: api
  owner: api                          # managed.roles에 존재해야 reconcile 성공
```

**Sync 순서**: managed.roles (Cluster 내부) → Database CRD. CNPG operator가 관계 처리.

### D7. App Connection 주입 규약 — **v0.2 재정의**

**Secret 이름 규약**: `<cluster>-<role>-credentials`
- 예: `pokopia-wiki-pg-api-credentials`, `pokopia-wiki-pg-scraper-credentials`
- Secret은 `kubernetes.io/basic-auth` 타입이므로 **username · password 두 키만** 포함.
- 호스트·DB 이름 등은 env literal로 주입.

**표준 Deployment env 패턴**:

```yaml
env:
  - name: POSTGRES_HOST
    value: pokopia-wiki-pg-rw             # CNPG가 자동 생성하는 Service
  - name: POSTGRES_PORT
    value: "5432"
  - name: POSTGRES_DB
    value: api
  - name: POSTGRES_USER
    valueFrom:
      secretKeyRef: { name: pokopia-wiki-pg-api-credentials, key: username }
  - name: POSTGRES_PASSWORD
    valueFrom:
      secretKeyRef: { name: pokopia-wiki-pg-api-credentials, key: password }
  - name: DATABASE_URL
    value: postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_HOST):$(POSTGRES_PORT)/$(POSTGRES_DB)?sslmode=require
```

**장점**:
- 시크릿은 password만 로테이션, 호스트·DB 이름은 정적 · env 이름 통제 100%
- `sslmode=require` 기본 (M8: require는 CA 불필요)

**공유 DB 시나리오-1 (v0.4 H1 명확화)**: 두 서비스가 **동일한 `<cluster>-<owner-role>-credentials` Secret 을 공유** 한다. `mode: reference` 서비스는 별도 role 도, 별도 SealedSecret 도 생성하지 않으며, owner 의 credentials 를 그대로 마운트한다. 이는 "참조(reference)" 라는 단어의 documentation-only 라벨 — **실체는 동일 계정 공유** 이다. 이 설계의 의도된 한계:

- ✅ **얻는 것**: 구현 단순성 · setup-app 코드 최소화 · SealedSecret 관리 부담 0 · connection string 일관.
- ⚠️ **잃는 것**: minimum privilege 불가 · `pg_stat_activity.usename` 기준 audit trail 구분 불가 · credential 로테이션 시 두 서비스 동시 재배포.
- 🎯 **의식적 타협**: 홈랩 모노레포의 "프로젝트 내부 서비스들은 한 DB 경계 내 동등 신뢰" 전제 하에 수용. 조직 경계·외부 팀 공유 시나리오에는 부적합.

**H4 반영 · 향후 readonly 분리 대비 (Phase 8 후속)**: readonly 권한 분리가 필요해지는 시점에 `mode: reference-readonly` 를 `.app-config.yml` 스키마에 **신규** 도입. 이때 setup-app 은 (1) 추가 role SealedSecret 생성 (2) `managed.roles[]` 에 readonly role 추가 (3) `GRANT CONNECT, USAGE, SELECT` SQL 을 initContainer/Job 으로 주입 (CNPG `Database` CRD 는 GRANT 미지원). 현재 `mode: reference` 와는 별도 모드로 공존.

### D8. 모노레포 파일 레이아웃 (v0.2 수정)

```
manifests/apps/<project>/
├── kustomization.yaml
├── common/
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── r2-backup.sealed.yaml              # R2 자격증명 (SealedSecret)
│   ├── role-secrets.sealed.yaml           # role password들 (SealedSecret · 각 role 1개)
│   ├── cluster.yaml                       # Cluster + managed.roles + plugins
│   ├── objectstore.yaml                   # Plugin ObjectStore CR
│   ├── scheduled-backup.yaml
│   └── database-shared.yaml               # (시나리오-1 전용)
└── services/
    ├── api/
    │   ├── kustomization.yaml
    │   ├── deployment.yaml                # env 규약 적용
    │   ├── database.yaml                  # (시나리오-2 전용)
    │   └── service.yaml
    └── scraper/
        └── ...
```

### D9. `.app-config.yml` 스키마 확장 (v0.1 동일)

```yaml
database:
  enabled: true
  version: "16"
  storage: 5Gi                          # default (D 시나리오 반영). 큰 DB는 앱에서 상향 (e.g. 10Gi, 20Gi)
  services:
    - service: api
      mode: owner                          # owner | reference | none
      name: api                            # DB 이름 (owner면 동일 이름의 role도 생성)
    - service: scraper
      mode: reference                      # 시나리오-1: A 의 credentials 그대로 공유 (별도 role·secret 없음 — §D7)
      ref: api                             # owner service 이름. setup-app 은 <cluster>-<ref>-credentials 를 마운트
    # 시나리오-2 분리 DB 시:
    # - service: scraper
    #   mode: owner
    #   name: scraper
    # 향후 readonly 권한 분리 (Phase 8 후속):
    # - service: scraper
    #   mode: reference-readonly           # 신규 mode · 별도 readonly role + GRANT SELECT
    #   ref: api
```

**mode 의미 요약 (v0.4 H1 확정)**:

| mode | role 생성 | SealedSecret 생성 | Database CR | env 주입 | 권한 |
|---|---|---|---|---|---|
| `owner` | ✅ (managed.roles) | ✅ (`<cluster>-<name>-credentials`) | ✅ (services/<svc>/ 또는 common/) | owner 자신 secret | DB 오너 (CREATE/GRANT) |
| `reference` | ❌ | ❌ | ❌ | `<cluster>-<ref>-credentials` 마운트 | owner 와 **동일 계정 공유** |
| `reference-readonly` (Phase 8+) | ✅ (readonly role) | ✅ | ❌ | 자체 readonly secret | `CONNECT + USAGE + SELECT` |
| `none` | ❌ | ❌ | ❌ | 주입 없음 | DB 미사용 서비스 |

### D10. setup-app 자동화 확장 (v0.2 업데이트)

**추가 step**:
1. `database.enabled=true` 시 common/에 매니페스트 생성:
   - cluster.yaml · objectstore.yaml · scheduled-backup.yaml (idempotent)
   - r2-backup.sealed.yaml (최초 프로젝트에서만, 템플릿 기반 seal)
2. 각 `services[].mode=owner` 당:
   - role-secret-<role>.sealed.yaml 생성 (composite action 내부에서 랜덤 패스워드 생성 → kubeseal 실행)
   - cluster.yaml의 managed.roles 배열에 엔트리 병합 (yq)
   - common/ 또는 services/<svc>/ 에 database.yaml 생성
3. Deployment 템플릿에 D7 env 패턴 주입 (yq)

**SealedSecret 자동화 (v0.4 확정)**: ARC runner 는 `actions-runner-system` 네임스페이스에 in-cluster 배포되어 있음 (`manifests/infra/arc-runners/values-runner.yaml:17`). kubeseal 은 `--controller-namespace sealed-secrets --controller-name sealed-secrets-controller` 플래그로 Service 를 직접 호출 — 외부 HTTPS endpoint 불필요, 공개 노출 회피.

**✅ 확정 근거**: §17 Q14 (ARC runner in-cluster). Phase 0 A-5 검증 필요.

### D11. ArgoCD AppProject 3축 확장 (v0.4 M2 전면 갱신)

CNPG + plugin + cert-manager 도입으로 infra AppProject (`manifests/infra/argocd/appproject-infra.yaml`) 에 **세 가지 축 모두 업데이트** 필요 (v0.3 에서 whitelist 만 언급되던 것을 교정).

#### (1) `clusterResourceWhitelist` — cluster-scoped 리소스 허용

추가 필요:
- CNPG: `postgresql.cnpg.io/v1` (Cluster·Backup·ScheduledBackup·Pooler·Publication·Subscription·Database) + webhook (`ValidatingWebhookConfiguration`·`MutatingWebhookConfiguration` 은 이미 허용됨)
- Plugin: `barmancloud.cnpg.io/v1` (ObjectStore) CRD + 플러그인 ClusterRole/ClusterRoleBinding
- cert-manager: `cert-manager.io/v1` (ClusterIssuer) — `Issuer`·`Certificate`·`CertificateRequest` 는 namespace-scoped 라 whitelist 불필요
- **참고**: CRD (`apiextensions.k8s.io/CustomResourceDefinition`) 는 이미 infra project 에 등재됨 (`appproject-infra.yaml:55`)

#### (2) `sourceRepos` — 허용 Helm/Git 저장소

현재 infra AppProject `sourceRepos` (실측 확인됨):
```yaml
sourceRepos:
  - "https://github.com/ukkiee-dev/homelab.git"
  - "https://bitnami-labs.github.io/sealed-secrets"
  - "https://traefik.github.io/charts"
  - "https://pkgs.tailscale.com/helmcharts"
  - "ghcr.io/actions/actions-runner-controller-charts"
```

추가 필요:
- `"https://charts.jetstack.io"` (cert-manager Helm)
- `"https://cloudnative-pg.github.io/charts"` (CNPG operator Helm)
- `"https://github.com/cloudnative-pg/plugin-barman-cloud"` (plugin manifest raw)

#### (3) `destinations` — 허용 대상 namespace

현재 infra AppProject `destinations` 에는 `cert-manager`, `cnpg-system` 둘 다 **누락**. 추가 필요:

```yaml
destinations:
  - namespace: cert-manager
    server: https://kubernetes.default.svc
  - namespace: cnpg-system
    server: https://kubernetes.default.svc
```

#### 실행 순서 (메모리 `project_argocd_appproject_cluster_resources` 준수)

AppProject 3축을 **Phase 2 설치 이전에 먼저 merge** 해야 한다 — 리소스 생성 시점에 AppProject 가 막으면 ArgoCD Application Sync 가 실패하기 때문. Phase 2 Task 순서:

1. (**Phase 2.0**) AppProject 3축 확장 PR 생성 + merge — CRD 아직 없으므로 whitelist 만 등재된 상태는 ArgoCD가 무해하게 수용.
2. (Phase 2.1) cert-manager / CNPG / plugin Application 생성.

### D12. ArgoCD sync wave & sync-options (v0.2 추가)

| 리소스 | wave | sync-options |
|---|---|---|
| cert-manager (Helm Application) | `-3` | `ServerSideApply=true, Replace=true, SkipDryRunOnMissingResource=true` |
| CNPG operator (Helm Application) | `-2` | 동일 |
| plugin-barman-cloud (manifest Application) | `-1` | 동일 |
| 프로젝트 Namespace + SealedSecret (role·R2) | `0` | 기본 |
| Cluster + ObjectStore + ScheduledBackup | `0` | 기본 |
| Database | `1` | 기본 |
| App Deployment | `2` | 기본 |

**H5 반영**: 모든 CRD-관련 Helm Application에 sync-options 명시. 메모리의 "큰 ConfigMap SSA 우회" 패턴과 일관.

### D13. TLS (v0.2 명확화)

- CNPG operator CA 자동 생성·로테이션
- 앱은 기본 `sslmode=require` (M8: 서버 인증서 자체는 앱이 체크하지 않음, CA mount 불필요)
- 필요 시 `sslmode=verify-full` 로 승격 — CA volume mount 예시 Runbook에서 다룸 (Phase 8)

### D14. NetworkPolicy (v0.4 H3 정정)

**K3s CNI 능력 정확한 기술**: K3s 번들 CNI 는 flannel(overlay) + kube-router(NetworkPolicy enforcer) 조합. **L3/L4 NetworkPolicy (ingress/egress · CIDR · port) 는 완전 지원** 한다. 지원하지 않는 것은 **FQDN 기반 egress** — 이것만 Cilium/Calico eBPF 등이 필요.

**실제 가능한 정책**:
- **ingress** (postgres pod로): 같은 namespace 앱 pod → TCP 5432 (앱 pod 라벨 기반)
- **ingress** (postgres pod로): `monitoring` namespace Alloy → TCP 9187
- **egress** (postgres pod에서): kube-dns (CoreDNS) UDP/TCP 53
- **egress** (postgres pod에서 → R2)**: Cloudflare 공식 IP range (https://www.cloudflare.com/ips/) 기반 CIDR 통제 **기술적으로 가능**. 다만 R2 전용 IP 가 Cloudflare Workers·CDN·DNS 등과 공유되어 **정밀도가 낮음** (R2 에만 열고 다른 Cloudflare 서비스는 막는 정책 불가). 홈랩 기준 이 정밀도 부족은 수용 가능 → Cloudflare IPv4/IPv6 range 기반 egress allow + 포트 443 로 타협.

**H3 반영 · §9 수정**: "R2 egress 통제는 CIDR 기반 **가능** 하나 R2 vs Cloudflare 타 서비스 **구분 불가** — 정밀도 낮음" 으로 솔직하게 적는다. Cilium 전환 (FQDN 통제) 은 §16 out-of-scope.

> **후속 개선 여지 (Low, §16 후보)**: Cloudflare IP range 기반 egress allow 를 NetworkPolicy 로 구현. 단 range 갱신 (공식 pool 변경) 감시 자동화 필요 — Renovate / 월 1회 CronJob 으로 fetch · diff · PR 자동화 가능.

### D15. 리소스 사이징 (v0.4 수정 · M3 반영)

- **Operator pod**: chart default (request 100m/200Mi · limit 미설정 또는 400Mi)
- **Plugin pod**: 추정 request 50m/100Mi · limit 200m/256Mi (Phase 1 실측)
- **cert-manager** (3 deployment: controller·webhook·cainjector): 합계 ~300Mi
- **Postgres instance**: request 100m/384Mi · limit 1000m/1Gi
- **Storage**: 5Gi (data+WAL 통합) + R2 backup

**피크24h × 1.3** 원칙은 Phase 5 이후 실사용 기반 재조정.

#### Postgres 내부 파라미터 튜닝 (v0.4 M3 신규)

CNPG 는 `Cluster.spec.postgresql.parameters` 로 PostgreSQL GUC 튜닝 지원. memory limit 1Gi 기준 **기본값 그대로는 OOM 리스크** — `shared_buffers` 기본(메모리 25%) = 256Mi 이고, `work_mem × connections` 합이 limit 초과 가능.

Phase 3 PoC 에서 다음 파라미터를 명시 pin 한다 (`Cluster.spec.postgresql.parameters`):

```yaml
spec:
  postgresql:
    parameters:
      shared_buffers: "256MB"          # 기본 유지 (25%)
      work_mem: "4MB"                  # default 4MB 유지, 연결당 × 복잡 쿼리당 할당
      max_connections: "50"            # default 100 → 50 으로 감축 (홈랩 워크로드 기준 overprovisioning 방지)
      maintenance_work_mem: "64MB"     # default 수준
      effective_cache_size: "512MB"    # OS cache 예측값 (memory limit 의 ~50%)
      wal_buffers: "16MB"              # shared_buffers 의 ~1/32
      # 로그
      log_min_duration_statement: "250ms"   # 느린 쿼리 감시
      log_checkpoints: "on"
```

**검증**: Phase 3 Task 3.x 에서 `kubectl cnpg psql <cluster> -- -c "SHOW ALL;" | grep -E 'shared_buffers|work_mem|max_connections'` 로 실제 적용 확인. Phase 5 알람 중 `CNPGTooManyConnections` 는 `max_connections` 80% 초과 시 발화 (§D16 신규 알람 후보).

### D16. 모니터링 & 알람 (v0.2 전면 개편)

**Scrape**: Alloy kubernetes_sd_configs 직접 (PodMonitor 없음)

```yaml
- job_name: cnpg
  kubernetes_sd_configs: [ { role: pod } ]
  relabel_configs:
    - source_labels: [__meta_kubernetes_pod_label_cnpg_io_cluster]
      action: keep
      regex: .+
    - source_labels: [__meta_kubernetes_pod_container_port_number]
      action: keep
      regex: "9187"
    - source_labels: [__meta_kubernetes_pod_label_cnpg_io_cluster]
      target_label: cluster
    - source_labels: [__meta_kubernetes_namespace]
      target_label: namespace
```

**대시보드**: CNPG 공식 Grafana dashboard import (Phase 4에서 최신 ID 확인).

**알람 규칙 (v0.2 재작성)** — 실제 exporter 메트릭 기반:

```yaml
# (1) Cluster collector health
- alert: CNPGCollectorDown
  expr: cnpg_collector_up == 0
  for: 5m
  labels: { severity: critical }
  annotations:
    summary: "CNPG collector down for {{ $labels.cluster }}"

# (2) Backup age (unix epoch 비교)
- alert: CNPGBackupTooOld
  expr: (time() - cnpg_collector_last_available_backup_timestamp) > 30 * 3600
  for: 10m
  labels: { severity: warning }
  annotations:
    summary: "Last successful backup for {{ $labels.cluster }} is > 30h old"

# (3) WAL archive backlog (ready 파일 누적)
- alert: CNPGWALArchiveStuck
  expr: cnpg_collector_pg_wal_archive_status{value="ready"} > 10
  for: 15m
  labels: { severity: warning }
  annotations:
    summary: "WAL archive backlog for {{ $labels.cluster }} exceeds 10 segments"

# (4) PVC 사용률
- alert: CNPGPVCDiskPressure
  expr: kubelet_volume_stats_used_bytes{persistentvolumeclaim=~".*-pg-.*"}
      / kubelet_volume_stats_capacity_bytes{persistentvolumeclaim=~".*-pg-.*"} > 0.8
  for: 15m
  labels: { severity: warning }
```

**Deprecation 주의**: (2)의 `cnpg_collector_last_available_backup_timestamp` 는 v1.26에서 deprecated. v1.30+ 전환 시 `barmancloud_*` plugin 메트릭으로 이관 예정. Runbook에 메트릭 마이그레이션 절차 기록.

**C2 반영 · 검증 필수**: Phase 4 진입 전 Phase 0 I-1에서 `curl <pod>:9187/metrics | grep cnpg_` 로 실존 확인, 결과를 Appendix C에 박제.

---

## 6. 모노레포 요구사항 매핑

### 6.1 시나리오-1: A 생성 / B 참조 (공유 DB)

**파일 구조**:
```
manifests/apps/pokopia-wiki/
├── common/
│   ├── role-secrets.sealed.yaml           # role=wiki의 SealedSecret 1개
│   ├── cluster.yaml                       # managed.roles: [wiki]
│   ├── objectstore.yaml
│   ├── scheduled-backup.yaml
│   └── database-shared.yaml               # Database name=wiki owner=wiki
└── services/
    ├── api/deployment.yaml                # POSTGRES_DB=wiki · user=wiki 
    └── scraper/deployment.yaml            # 동일 secret 참조
```

시나리오-1 에서 scraper 도 동일 role(wiki) 로 접근하며 별도 role·SealedSecret 을 만들지 않는다 (§D7 `mode: reference` 정의). 권한 분리는 Phase 8 `mode: reference-readonly` 후속 도입 시점에.

### 6.2 시나리오-2: A·B 각자 독립 DB

**파일 구조**:
```
manifests/apps/pokopia-wiki/
├── common/
│   ├── role-secrets.sealed.yaml           # api + scraper 각각 2개
│   ├── cluster.yaml                       # managed.roles: [api, scraper]
│   ├── objectstore.yaml
│   └── scheduled-backup.yaml
└── services/
    ├── api/
    │   ├── database.yaml                  # Database name=api owner=api
    │   └── deployment.yaml
    └── scraper/
        ├── database.yaml                  # Database name=scraper owner=scraper
        └── deployment.yaml
```

요구사항 충족: ✅ 두 시나리오 모두 커버.

---

## 7. setup-app 자동화 확장 상세 (v0.2 업데이트)

### 7.1 입력 확장

```yaml
inputs:
  database-enabled:        { required: false, default: "false" }
  database-mode:           { required: false, default: "none", description: "none | owner | reference" }
  database-name:           { required: false, default: "" }
  database-ref:            { required: false, default: "", description: "mode=reference 시 대상 DB 이름" }
```

### 7.2 composite step 추가 (의사코드)

```bash
# 1) common/ 초기화 (최초 서비스일 때)
if [ "$DATABASE_ENABLED" = "true" ] && [ ! -f common/cluster.yaml ]; then
  render template → common/cluster.yaml
  render template → common/objectstore.yaml
  render template → common/scheduled-backup.yaml

  # R2 자격증명 SealedSecret
  if [ ! -f common/r2-backup.sealed.yaml ]; then
    render template → common/r2-backup.sealed.yaml  # placeholder, 수동 seal 유도
    echo "⚠️ r2-backup.sealed.yaml 수동 seal 필요"
  fi
fi

# 2) role password SealedSecret 생성 (mode=owner)
if [ "$DATABASE_MODE" = "owner" ]; then
  PASSWORD=$(openssl rand -base64 24)
  TMP_SECRET=$(mktemp)
  cat > "$TMP_SECRET" <<EOF
apiVersion: v1
kind: Secret
type: kubernetes.io/basic-auth
metadata:
  name: ${APP}-pg-${DATABASE_NAME}-credentials
  namespace: ${APP}
  labels:
    cnpg.io/reload: "true"
stringData:
  username: ${DATABASE_NAME}
  password: ${PASSWORD}
EOF
  # v0.4 (C2 반영): §17 Q14 확정대로 ARC runner 는 actions-runner-system 네임스페이스의
  # in-cluster pod 이므로 sealed-secrets-controller Service 를 직접 호출한다.
  # 외부 HTTPS endpoint (--fetch-cert) 는 불필요 — kubeseal 이 kubeconfig 권한으로 controller RPC 호출.
  kubeseal --controller-namespace sealed-secrets \
           --controller-name sealed-secrets-controller \
           --format=yaml \
    < "$TMP_SECRET" \
    >> common/role-secrets.sealed.yaml

  # cluster.yaml의 managed.roles 배열에 엔트리 병합
  yq eval -i '.spec.managed.roles += [{"name": env(DATABASE_NAME), "ensure": "present", "login": true, "passwordSecret": {"name": env(APP)+"-pg-"+env(DATABASE_NAME)+"-credentials"}}]' common/cluster.yaml

  # Database CRD 생성
  if [ -n "$SERVICE" ]; then
    render template → services/$SERVICE/database.yaml
  else
    render template → common/database-shared.yaml
  fi
fi

# 3) Deployment env 주입 (D7 패턴)
yq eval -i '.spec.template.spec.containers[0].env += [...]' services/$SERVICE/deployment.yaml
```

**✋ Phase 0 확인**: kubeseal이 ARC runner에서 접근 가능한 cert endpoint 필요. 현재 홈랩 설정 점검.

---

## 8. 백업 · 복구 전략 (v0.2 plugin 기반)

### 8.1 백업 주기 & Retention

| 항목 | 값 |
|---|---|
| ScheduledBackup cron | `0 0 18 * * *` (UTC) = KST 03:00 |
| Retention | 14일 |
| WAL archiving | 연속 (plugin 에이전트) |
| 타겟 | R2 `homelab-db-backups/<project>` |
| 용량 | 프로젝트당 500MB–2GB |

### 8.2 PITR 복구 절차 (v0.4 H4 반영 · Git vs kubectl 분기 확정)

> **핵심 원칙** (메모리 `feedback_argocd_changes`·`project_argocd_multisource_deadlock`): `selfHeal=true` 환경에서 kubectl 로 Cluster 매니페스트를 조작하면 ArgoCD 가 즉시 원복한다. 반드시 **Git PR 경유** 하되 일시적으로 `selfHeal=false` 로 조정하여 reconcile race 를 차단한다.

#### Step 0 — 사전 확인
- [ ] 대상 PVC `reclaimPolicy` 확인: `kubectl get pv $(kubectl -n <project> get pvc <project>-pg-1 -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'`. local-path 기본값 `Delete` 이므로 Cluster 삭제 시 PV 도 소거됨 — **의도된 동작**. `Retain` 이면 Step 4 전에 수동 `kubectl delete pv` 필요 (동일 이름 재사용 충돌 방지).
- [ ] 복구 시점(UTC) 확정 · R2 bucket 내 해당 시점 포함하는 base+WAL 존재 여부 `kubectl cnpg status <cluster>` + `rclone ls r2:homelab-db-backups/<project>/` 로 확인.

#### Step 1 — ArgoCD 일시 unmanage (Git PR ①)
- [ ] PR ① 생성: 대상 Application 매니페스트에 `spec.syncPolicy.automated = null` 또는 `automated.selfHeal: false` 적용 (둘 중 자동화 범위에 따라 선택). CR 자체는 아직 건드리지 않음.
- [ ] merge 후 ArgoCD reconcile 대기 (≤ 3 min) → Application 이 OutOfSync 이더라도 selfHeal 작동 안 함 확인.
- [ ] `argocd app sync <app> --dry-run` 으로 예상 diff 미리 관찰.

#### Step 2 — 원본 Cluster 삭제 (kubectl)
- [ ] `kubectl -n <project> delete cluster <project>-pg` — finalizer cascade 로 PVC/Service/Secret 일부 정리.
- [ ] CR 삭제 지연 시 (webhook 데드락 등): §9 M3 escape 절차 (`operator scale 0`) 사용.
- [ ] 남은 리소스 수동 정리: `kubectl -n <project> delete pvc -l cnpg.io/cluster=<project>-pg` (PV reclaim 완료까지 대기).

#### Step 3 — recovery Cluster 선언 (Git PR ②)
- [ ] PR ② 생성: `common/cluster.yaml` 에 `spec.bootstrap.recovery` + `spec.externalClusters[]` 블록 추가.
  ```yaml
  spec:
    bootstrap:
      recovery:
        source: <project>-pg-backup-source
        recoveryTarget:
          targetTime: "2026-04-25 14:30:00+00"  # UTC
    externalClusters:
      - name: <project>-pg-backup-source
        plugin:
          name: barman-cloud.cloudnative-pg.io
          parameters:
            barmanObjectName: <project>-backup
            serverName: <project>-pg
  ```
- [ ] merge + 수동 sync: `argocd app sync <app>` (selfHeal 은 여전히 false 이므로 수동 트리거 필요).
- [ ] Cluster pod ready 확인: `kubectl cnpg status <project>-pg` · Database CR reconcile 성공 확인.

#### Step 4 — managed.roles·Database 재적용 & 앱 rolling restart
- [ ] `managed.roles[]` 과 Database CR 은 이미 Git 에 있으므로 Cluster recovery 완료 직후 operator 가 자동 reconcile.
- [ ] 앱 Deployment rolling restart: `kubectl -n <project> rollout restart deploy/<app>` — secret 참조 변경 없으므로 env 재주입만으로 재연결.

#### Step 5 — ArgoCD selfHeal 복원 (Git PR ③)
- [ ] PR ③ 생성: `spec.bootstrap.recovery` 블록 **제거** + `syncPolicy.automated.selfHeal: true` 원복.
- [ ] merge → 정상 selfHeal 상태로 복귀.
- [ ] post-mortem: PITR 수행 기록 · 시점 · 소요 시간을 `docs/runbooks/postgresql/cnpg-pitr-restore.md` 부록에 누적.

> **주의**: Step 1 과 Step 5 의 PR 은 **반드시 인간이 리뷰** · 자동 merge 금지. Step 3 PR 은 Step 2 완료 직후 즉시 merge 해야 한다 — 지연 시 recovery window 내 WAL 누락 위험.

Runbook: `docs/runbooks/postgresql/cnpg-pitr-restore.md` — skeleton 은 **Phase 4 직후** commit (drills 기록 누적 목적, 리뷰 L8 반영), 완성은 Phase 9.

### 8.3 DR 검증 주기

- 월 1회 PITR 드라이런 (`dr-verification` 스킬)
- 분기 1회 백업 무결성 smoke test (제안: §16에서 자동화)

### 8.4 R2 single source 리스크 (v0.4 I-7 조사 결과 반영)

R2 계정 장애·실수 삭제 시 복구 불능. 명시적 인정 · 완화 옵션:

> **Phase 0 I-7 조사 결과 (2026-04-20 박제: `_workspace/cnpg-migration/14_r2-object-lock.md`)**:
> - **R2 bucket versioning 은 2026-04 현재 미지원** — `PutBucketVersioning` / `GetBucketVersioning` 모두 unimplemented. 공식 로드맵 공개 없음
> - **S3 `ObjectLockConfiguration` API 는 모두 미지원** — governance / compliance mode 개념 자체가 없음
> - 대신 Cloudflare 독자 **"R2 Bucket Locks" (2025-03-06 GA)** 존재: prefix 기반 retention rule, Age/Date/Indefinite, 1,000 rule/bucket. per-object legal hold 없음, compliance mode 없음 (rule 제거 가능 → 진정한 WORM 아님)
> - Terraform provider v5.4.0+ 가 `cloudflare_r2_bucket_lock` + `cloudflare_r2_bucket_lifecycle` 리소스 제공

**v1.0 목표 (I-7 결과 반영)**:
- ~~R2 bucket versioning~~ **삭제** (미지원 확정)
- **R2 Bucket Lock (prefix=`wal/` Age=21d rule)** 을 Terraform 으로 선언 — WAL 최소 보관 하한선 보호
- **R2 bucket lifecycle (base/ prefix 14d + grace 자동 만료)** 로 Barman `retentionPolicy: 14d` 와 정합
- **Phase 4 E2E 검증 필수**: Barman `backup-delete` 가 Bucket Lock rule 과 충돌하지 않는지 POC — R2 Bucket Lock 은 Barman 3.17+ 의 "lock-aware delete" (S3 Object Lock 전제) 와 프로토콜이 다르므로 호환성 미검증

**§16 후속**:
- **진정한 immutable WORM / ransomware-proof**: R2 단독 불가. Backblaze B2 (S3 Object Lock GA) 또는 AWS S3 Glacier Instant Retrieval 2차 사이트 추가하는 **이기종 이중화** (v2.0 목표)
- **외장 SSD mirror**: `postgresql-backups-ssd` PVC (external-ssd, 20Gi) 를 재활용하여 CNPG PVC → SSD mirror CronJob 추가 — 단기 이중화 옵션 (§16)
- **R2 Bucket Lock + barman-cloud E2E 호환성 upstream 이슈 보고**: Phase 4 POC 결과에 따라 조건부

---

## 9. 보안 · 네트워크 (v0.2 솔직 반영)

| 영역 | 조치 | 한계 |
|---|---|---|
| Role password | 사용자 생성 SealedSecret (namespace-scoped, M2 반영) | cluster-wide scope 회피 |
| R2 credential | SealedSecret (namespace-scoped) | 동일 |
| TLS | Operator CA 자동, 앱 `sslmode=require` 기본 | verify-full 미채택 |
| NetworkPolicy ingress | 앱→postgres, Alloy→postgres metrics | 가능 |
| NetworkPolicy egress | kube-dns UDP/53 · Cloudflare IP range CIDR + TCP/443 | **FQDN 통제 불가** (K3s flannel+kube-router 는 L3/L4 까지만 지원, Cilium 미도입). R2 vs Cloudflare 타 서비스 **구분 불가** — CIDR 정밀도 낮음 |
| RBAC | operator · plugin ServiceAccount 최소 권한 | CNPG chart defaults 신뢰 |
| Webhook | validating webhook `Fail` → 데드락 시 operator scale 0 escape (M3) | Runbook 명시 |

### M2 재평가: SealedSecret scope

- **v0.1 주장**: cluster-wide scope → 리뷰어 격상 요청 수용
- **v0.2 채택**: **namespace-scoped** 기본. setup-app에서 프로젝트 namespace마다 개별 seal.
- **R2 credential**: 각 프로젝트 namespace마다 re-seal하되, 평문 credential은 외부 vault/파일에 1회 보관 후 composite action이 kubeseal 호출.

### M3 webhook 데드락 escape 절차

```bash
# operator webhook이 reject해서 CR 삭제 불가 시
kubectl -n cnpg-system scale deploy/cnpg-controller-manager --replicas=0
# 이제 kubectl delete cluster/* 가능
# 복구 후 operator 재기동
kubectl -n cnpg-system scale deploy/cnpg-controller-manager --replicas=1
```

Runbook에 기록 (Phase 8).

---

## 10. 모니터링 · 알람

### 10.1 메트릭 수집

- CNPG pod `/metrics` 9187 포트를 Alloy `kubernetes_sd_configs`로 직접 scrape (PodMonitor CRD 미사용)
- 추가: operator 자체 메트릭 (cnpg-system namespace · 포트 8080)

### 10.2 대시보드

- CNPG 공식 Grafana JSON import (Phase 0에서 최신 버전 ID 확정)
- 패널: Cluster status, TPS, connections, cache hit ratio, WAL rate, backup age, PVC usage

### 10.3 알람 규칙

§D16 참조 (실제 exporter 메트릭 기반 4종).

### 10.4 알람 검증 (M4 반영)

- 테스트용 임계값 하향 대신 **일시 임시 규칙** 추가 → 발화 확인 → 규칙 삭제
- 또는 Alertmanager silence로 라우팅만 검증 (Grafana alert state history 오염 방지)

---

## 11. 리소스 예산 (v0.2 수정)

### 11.1 현재 Baseline (Phase 0 I-4에서 실측 교체 예정)

> **v0.4 주의 (I-0 반영)**: 현재 클러스터의 Bitnami 는 실제로 **v18.3.0** (chart `postgresql-18.5.15`) 이 `helm install` 로 배포된 상태 — v0.3 의 "~100Mi" 추정은 v16 기준이므로 재검증 필요. v18 exporter sidecar 포함 시 150~200Mi 로 증가했을 가능성. Phase 0 I-4 에서 `kubectl top pod -n apps -l app.kubernetes.io/name=postgresql` 실측 권장.

| 구성요소 | RAM (추정) |
|---|---|
| K3s 시스템 | ~2.3Gi |
| ArgoCD | ~500Mi |
| Traefik · cloudflared · Tailscale | ~300Mi |
| VictoriaMetrics · Logs · Grafana · Alloy | ~1.5Gi |
| Sealed Secrets + ARC | ~200Mi |
| 기존 Bitnami postgres (v18.3.0, exporter 포함) | ~150Mi (추정, I-4 갱신 예정) |
| 앱들 (homepage/adguard/uptime/test-web) | ~500Mi |
| **합계 baseline** | **~5.45Gi** |

### 11.2 CNPG 도입 후 (프로젝트 수별)

| 시나리오 | 추가 RAM | 누적 |
|---|---|---|
| + cert-manager (3 pod) | +300Mi | 5.7Gi |
| + CNPG operator | +200Mi | 5.9Gi |
| + plugin-barman-cloud | +150Mi | 6.05Gi |
| + 1 프로젝트 Cluster | +400Mi | 6.45Gi |
| + 3 프로젝트 Cluster | +1200Mi | 7.25Gi |
| + 5 프로젝트 Cluster | +2000Mi | 8.05Gi |

- OrbStack 12Gi 설정에서 **5 프로젝트까지 안전** (headroom ~4Gi)
- Bitnami 폐기 시 -100Mi 상쇄
- **재검토 트리거**: 5 프로젝트 초과 시 공유 Cluster 전환 재평가 (D1 에스케이프 해치)

### 11.3 Storage

| 리소스 | 크기 | 개수 | 합계 |
|---|---|---|---|
| postgres PVC (data+WAL 통합, default) | 5Gi | N | 5N Gi |
| R2 백업 | ~500MB–2Gi | N | ~1–2N Gi (~$0.015–0.03N/월) |

**default 5Gi 원칙 (D 시나리오 확정 반영)**: K3s 번들 local-path-provisioner (v0.0.31, 2025-01-24) 는 PVC resize 미지원 — upstream issue #190 여전히 OPEN. resize 비용이 backup+restore 절차라 **초기에 넉넉하게 시작** (1년 growth 여유). 큰 DB 예상되면 `.app-config.yml` 의 `database.storage` 로 추가 상향 (e.g. `10Gi`, `20Gi`).

**관련 후속 계획**:
- Runbook `docs/runbooks/storage/cnpg-pvc-resize.md`: backup → bootstrap.recovery → endpoint swap 절차 (Phase 9)
- **StorageClass 전환 = 잔여 TODO (CNPG 완료 후 실행 확정)**: OpenEBS LocalPV Hostpath 로 전환하여 근본 해결 → [docs/plans/2026-04-20-openebs-localpv-migration-followup.md](2026-04-20-openebs-localpv-migration-followup.md)

**WAL archive 모니터링 필수**: default 5Gi도 WAL archive 지연 누적 시 언젠가 full. Phase 5 `CNPGWALArchiveStuck` 알람이 조기 탐지 역할. R2 archive 가 막히면 WAL이 PVC에 쌓여 full → DB down. app owner 에게 `database.storage` 재상향 권장.

---

## 12. 마이그레이션 Phase 0–8 (v0.2 재구성)

### Phase 0 — Decision + Investigation + Action (1–2일, blocking gate)

#### Decision (v0.3 확정 + v0.4 추가)
- [x] **D-1 (v0.3 확정)**: Backup 방식 = **Plugin** (`plugin-barman-cloud + ObjectStore CR`) — §17 Q3
- [x] **D-2 (v0.3 확정)**: cert-manager 신규 도입 — §17 Q13
- [x] **D-3 (v0.3 확정)**: SealedSecret scope = namespace-scoped — §17 Q6
- [x] **D-4 (v0.3 확정)**: kubeseal cert endpoint = ARC runner → `sealed-secrets-controller` Service 직접 호출 — §17 Q14
- [x] **D-5 (v0.4 확정 · 리뷰 C1 반영)**: ArgoCD Kustomize+Helm 렌더 전략 = **(b) multi-source Application**
  - 홈랩 전례: `grep -rn "kustomize.buildOptions\|helmCharts" manifests/` → 0건. `argocd/applications/infra/traefik.yaml` 이 이미 `sources[]` (chart + Git values) 패턴 사용.
  - **옵션 (a) argocd-cm 전역 `--enable-helm` 기각**: 모든 Application 렌더 경로에 영향 → 회귀 테스트 부담 · ServerSideApply drift 예상 · 홈랩 helmCharts 전례 0건.
  - **옵션 (b) multi-source 채택 (최종)**: 각 Application 이 `spec.sources[0]` Helm chart + `spec.sources[1]` Git overlay (values.yaml + 선택적 Kustomize 리소스) 로 구성. traefik 와 동일 패턴 → 인지 부담 최소.
  - **주의 (메모리 `project_argocd_multisource_deadlock`)**: sources[] 배열 순서·ref·targetRevision 변경은 항상 Git PR 경유. 실수 시 kubectl patch 복구 필요 가능.
  - **결정 박제**: `_workspace/cnpg-migration/12_kustomize-helm-decision.md`. §A.1/§A.2 는 multi-source 레이아웃으로 전면 재작성 완료.

#### Investigation (Appendix C 박제)

> **v0.4 확장**: 리뷰 지적(I-0, I-2a, I-7) + 리뷰 누락분(I-0a) 4건 신규 추가. 기존 I-1~I-6 유지.

- [x] **I-0 (pre-verified 2026-04-20 · v0.4 신규)**: 현재 상태 팩트체크 완료
  - `helm list -n apps` → `postgresql-18.5.15` (deployed, app v18.3.0) 확인
  - `kubectl -n apps get sts,svc,pvc,secret | grep postgres` → StatefulSet·Service(3종)·PVC(2종)·Secret(4종) 존재
  - `grep -rn postgresql manifests/apps/postgresql/` → backup 3개 매니페스트만 존재, StatefulSet/Service/PVC 매니페스트 **없음**
  - **결과 박제**: §1.1 에 Git drift 박스로 반영. Phase 8 전면 재설계 (§12 Phase 8, A1 참조)
- [ ] **I-0a (v0.4 신규 · 리뷰 누락 보완)**: Bitnami drift 대응 방침 결정
  - 옵션 (α) "**helm uninstall 후 CNPG 로 교체**" — v0.4 권장 기본. Phase 8 에서 `helm uninstall postgresql -n apps` 선행, 이후 ArgoCD Application 삭제 + 매니페스트 정리. 실사용 0 이므로 데이터 손실 리스크 없음.
  - 옵션 (β) "**drift 를 Git 으로 먼저 박제 후 폐기**" — Bitnami chart 를 Application 으로 정식 승격시킨 다음 Phase 8 에서 정상 cascade 삭제. 과도한 우회 — 채택 안 함.
  - **결정 박제**: `_workspace/cnpg-migration/13_bitnami-drift-decision.md` 에 옵션·근거·실행 커맨드 기록
- [ ] **I-1**: 메트릭 dump는 Phase 0 시점에 Cluster 부재라 불가 → **Phase 3 Task 3.8 에서 PoC Cluster 기반으로 실행** · 결과는 Appendix C.1 에 박제 · Phase 5 알람 규칙의 실존 메트릭 근거로 사용
- [ ] **I-2**: CNPG operator · plugin · cert-manager · postgres image 최신 stable 태그 pin + `helm show values` 스키마 덤프 (Phase 0 실행)
- [ ] **I-2a (v0.4 신규 · H2 반영)**: CNPG `Database` CRD stability level 검증
  - `kubectl explain database.spec --api-version=postgresql.cnpg.io/v1 --recursive | head -80` 출력 박제
  - CNPG 공식 릴리스 노트 (v1.25 도입, v1.26~) 에서 `Database` 리소스의 graduation 상태 (alpha/beta/GA) 확인
  - GA 미도달 시 **D6 전략 대안**: managed.roles 만 선언, DB 는 initContainer psql `CREATE DATABASE IF NOT EXISTS` 폴백 (Phase 6 조건부 적용)
  - 결과 박제: Appendix C.2
- [ ] **I-3**: CNPG 공식 Grafana dashboard ID 확인 + VM 데이터소스 호환성 검증
- [ ] **I-4**: `kubectl top nodes`, VM PromQL로 현재 baseline 실측 → §11.1 갱신 (Bitnami 18 실측 메모리 포함)
- [ ] **I-5**: operator chart default resources 실측 → §11.2 갱신
- [x] **I-6 (pre-verified 2026-04-20)**: local-path-provisioner v0.0.31 resize **미지원** 확정 (Rancher issue #190 OPEN, allowVolumeExpansion 필드 부재). **D 시나리오** 로 default 5Gi 반영 완료. Phase 0 실행 시 재검증만 → `_workspace/cnpg-migration/11_resize-support.md`. C 후속(OpenEBS) 은 별도 md 의 T1 trigger 감시
- [ ] **I-7 (v0.4 신규 · M7 반영)**: R2 bucket versioning + Object Lock (retention lock) 현재 지원 범위 + barman-cloud 호환성 조사
  - Cloudflare 공식 문서에서 R2 Object Lock S3 API compatibility 범위 확인 (2024-2025 rollout 단계 — 전체 지원 여부 불확실)
  - Terraform `cloudflare_r2_bucket` provider 에서 versioning/lock 속성 지원 여부
  - barman-cloud (plugin) 이 versioned bucket 에서 잘 작동하는지 — 구 버전 객체 GC 정책이 `retentionPolicy` 와 충돌하지 않는지
  - 결과 박제: `_workspace/cnpg-migration/14_r2-object-lock.md`. 지원 부족 시 §8.4 를 "v1.0 은 bucket versioning 만, Object Lock 은 §16 후속" 으로 재조정

#### Action (환경 준비)
- [ ] **A-1**: R2 버킷 `homelab-db-backups` 생성 + API 토큰 발급 (Object R+W)
- [ ] **A-2**: OrbStack 메모리 12Gi 설정 확정 (미완 시 조정)
- [ ] **A-3**: infra AppProject `clusterResourceWhitelist` diff 준비 (CNPG·plugin·cert-manager CRD)
- [ ] **A-4**: 테스트 namespace 이름 결정 (`pg-trial` 권장)
- [ ] **A-5**: kubeseal `--fetch-cert` endpoint 검증 (cluster-wide 공개 또는 kubeconfig 우회)

**Go/No-Go 기준**: Decision 4건 확정 · Investigation 5건 결과 박제 · Action 5건 완료.

### Phase 1 — cert-manager 설치 (1일)

**Phase 1.0 — multi-source 스캐폴딩 준비 (D-5 (b) 확정)**
- [ ] `argocd/applications/infra/traefik.yaml` 의 `spec.sources[]` 패턴을 모범 예시로 확인 · `_workspace/cnpg-migration/12_kustomize-helm-decision.md` 결정 박제
- [ ] `manifests/infra/cert-manager/` 디렉토리에 namespace.yaml + values.yaml + kustomization.yaml 작성 (§A.1 참조)
- [ ] Task 1.3 ArgoCD Application 을 `sources[]` 2개 (chart + Git values) 형태로 선언

**Phase 1.1 — cert-manager 배포**
- [ ] `manifests/infra/cert-manager/` 작성 (Helm + custom values: operator만, 글로벌 ClusterIssuer는 Phase 8 별도)
- [ ] ArgoCD Application (syncWave=-3)
- [ ] CRD·webhook 확인
- [ ] 기존 Traefik ACME 트래픽 영향 없음 확인 (cert-manager는 CR 기반, Traefik ACME는 서버 파일 기반 — 격리됨)

### Phase 2 — CNPG operator + Plugin 설치 (1–2일)

**Phase 2.0 — AppProject 3축 확장 (v0.4 M2 신규, 선행 PR)**
- [ ] `manifests/infra/argocd/appproject-infra.yaml` 에 추가:
  - `sourceRepos`: `charts.jetstack.io`, `cloudnative-pg.github.io/charts`, `github.com/cloudnative-pg/plugin-barman-cloud`
  - `destinations`: `cert-manager`, `cnpg-system` namespace
  - `clusterResourceWhitelist`: `postgresql.cnpg.io/*`, `barmancloud.cnpg.io/ObjectStore`, `cert-manager.io/ClusterIssuer`
- [ ] merge + ArgoCD reconcile 완료 확인 (기존 Application 영향 없음)

**Phase 2.1 — 설치**
- [ ] `manifests/infra/cnpg-operator/` 작성 (Helm Application, syncWave=-2)
- [ ] `manifests/infra/cnpg-barman-plugin/` 작성 (manifest Application from upstream release, syncWave=-1)
- [ ] CRD 8종(Cluster·Backup·ScheduledBackup·Pooler·Publication·Subscription·Database·ObjectStore) 등록 확인
- [ ] operator + plugin pod Running
- [ ] Plugin의 gRPC Service · cert-manager Certificate 정상 발급 확인

### Phase 3 — 첫 Cluster PoC (1일)

- [ ] `pg-trial` namespace 수동 생성
- [ ] role-secret.sealed.yaml 하나 생성 (수동 kubeseal)
- [ ] Cluster 선언 (managed.roles 포함)
- [ ] `kubectl cnpg status pg-trial-pg` 정상 + role 생성 확인 (`\du` psql)
- [ ] Database CR 적용 + owner 매칭 성공
- [ ] App이 env로 연결 시도 — psql 접속 성공
- [ ] Teardown: namespace 삭제 → PVC·secret 깨끗이 정리 확인

### Phase 4 — 백업 통합 (1–2일)

- [ ] r2-pg-backup SealedSecret 생성
- [ ] ObjectStore CR 생성
- [ ] Cluster.spec.plugins에 barman-cloud 참조 추가
- [ ] on-demand Backup 1회 수동 트리거
- [ ] R2 bucket에서 `base/`·`wals/` 생성 확인
- [ ] ScheduledBackup CR 추가 · 다음날 자동 실행 검증
- [ ] **PITR 드라이런**: 별도 namespace bootstrap.recovery → psql 접속 성공
- [ ] `docs/runbooks/postgresql/cnpg-pitr-restore.md` 초안

### Phase 5 — 모니터링 통합 (1일)

- [ ] Alloy scrape config 추가 (§D16)
- [ ] VM에서 4개 알람 메트릭 실존 PromQL 검증
- [ ] Grafana dashboard import + variable 설정
- [ ] 알람 규칙 4종 추가 (§D16)
- [ ] 임시 rule 1개로 테스트 발화 (silence 또는 라우팅만 검증, Grafana state history 오염 방지)

### Phase 6 — 첫 실제 프로젝트 전환 (1–2일)

- [ ] 대상 선정 (신규 테스트용 or `pg-demo` 더미 프로젝트)
- [ ] common/ 매니페스트 6종 수동 작성 (cluster·objectstore·scheduled-backup·r2-backup·role-secrets·database-shared)
- [ ] 서비스 Deployment에 D7 env 패턴 적용
- [ ] ArgoCD sync → 시나리오-1 (공유 DB) 동작 검증
- [ ] 다른 더미 프로젝트로 시나리오-2 (분리 DB) 동작 검증

### Phase 7 — setup-app 자동화 (2–3일)

- [ ] `.app-config.yml` 스키마 확장 (database 블록) · **기존 앱 파일 스키마 diff 검사 (M9)**
- [ ] `.github/actions/setup-app/database/` 서브 composite 생성
- [ ] 템플릿 파일 추가: `.github/templates/cnpg/*.yaml.tpl`
- [ ] `_create-app.yml`·`_sync-app-config.yml` 파서 업데이트
- [ ] app-starter 외부 레포에 D7 env 예시 블록 추가
- [ ] 테스트 프로젝트 setup-app 실행 → 매니페스트·ArgoCD·Pod·DB 연결까지 end-to-end
- [ ] **Renovate packageRules 업데이트 (M10)**: CNPG minor·postgres image auto-merge 정책 조정

### Phase 8 — 기존 Bitnami 폐기 (v0.4 A1 전면 재설계, 1일)

> **v0.3 → v0.4 변경 이유**: I-0 팩트체크 결과 Bitnami StatefulSet 은 **ArgoCD 관리 밖** (`helm install` 직접 배포, Git drift). v0.3 의 "ArgoCD Application `postgresql` 삭제 (finalizer cascade)" 로는 Bitnami 리소스를 제거하지 못한다. Helm release uninstall 선행 필요.

#### Phase 8.0 — 사전 조건
- [ ] CNPG 로 마이그레이션된 실사용 앱이 **30일 이상 안정 운영** 확인 (metric: `CNPGCollectorDown` false positive 0, 백업 성공률 100%)
- [ ] Phase 0 I-0a 결정 (옵션 α "helm uninstall 후 CNPG 로 교체") 재확인

#### Phase 8.1 — 참조 0건 검증
- [ ] `grep -rn postgresql-auth manifests/` — backup CronJob 외 참조 0건 (있으면 먼저 CNPG credentials 로 전환)
- [ ] `kubectl get pods -A -o yaml | grep postgresql-auth` — 실행 중 pod 참조 0건
- [ ] `kubectl get pods -A -o yaml | grep -E "postgresql(-hl|-metrics)?:5432"` — 호스트 이름 참조 0건

#### Phase 8.2 — 마지막 백업 보존
- [ ] `kubectl -n apps patch cronjob postgresql-backup --patch '{"spec":{"suspend":true}}'` — 자동 실행 중단
- [ ] 마지막 수동 pg_dump 실행 (실사용 0 이면 글로벌만):
  ```bash
  kubectl -n apps create job --from=cronjob/postgresql-backup postgresql-backup-final
  ```
- [ ] R2 에 `archive-20YYMMDD/` prefix 로 수동 복사 (rclone) — 14일 retention 대상 아님
- [ ] **백업 무결성 검증 (v0.4 M5 신규)**:
  ```bash
  # 최신 dump 다운로드 후 pg_restore --list 로 목차 검증
  rclone copy r2:homelab-postgresql-backup/daily/$(최신파일).dump /tmp/
  pg_restore --list /tmp/$(최신파일).dump | head -20
  ```
  리스트 출력되면 파일 정상. 에러 시 Phase 8 중단 후 원인 조사.

#### Phase 8.3 — Helm release uninstall (v0.4 A1 신규 · 핵심 단계)
- [ ] `helm list -n apps` 로 `postgresql-18.5.15` deployed 확인
- [ ] `kubectl -n apps get pvc data-postgresql-0 -o jsonpath='{.spec.volumeName}'` 로 PV 이름 기록 (retain 확인)
- [ ] `helm uninstall postgresql -n apps` 실행
  - 이 명령은 Helm release 관리 대상 리소스 (StatefulSet, Service, ServiceAccount, 관련 ConfigMap) 를 모두 삭제
  - PVC 는 Helm 정책상 삭제되지 않는 경우가 많음 — 별도 삭제 필요
- [ ] 잔존 확인: `kubectl -n apps get sts,svc,pvc | grep -i postgres` 출력에 **`postgresql-hl`, `postgresql`, `postgresql-metrics`, `data-postgresql-0` 부재** 확인
- [ ] `postgresql-metrics` Service 가 drift 로 2d 3h 전 생성된 경우 별도 삭제 가능성 — `kubectl -n apps delete svc postgresql-metrics` 로 명시적 제거

#### Phase 8.4 — ArgoCD Application + 잔존 리소스 정리
- [ ] `data-postgresql-0` PVC 수동 삭제: `kubectl -n apps delete pvc data-postgresql-0` (PV reclaim 기본 `Delete`)
- [ ] `postgresql-auth` SealedSecret 삭제: 이 Secret 은 drift (Git 에 없음) 또는 과거 매니페스트 — `kubectl -n apps delete secret postgresql-auth sh.helm.release.v1.postgresql.v1 sh.helm.release.v1.postgresql.v2`
- [ ] ArgoCD Application `postgresql` 삭제: Git 에서 `argocd/applications/apps/postgresql.yaml` 제거 + `manifests/apps/postgresql/` 전체 `git rm` (backup CronJob·backup-storage·r2 SealedSecret 통째)
- [ ] external-ssd PVC `postgresql-backups-ssd` 유지 여부 결정:
  - 옵션 (i) **archive-only 유지**: 신규 CNPG Cluster 도 `/backups/` 동일 공간에 pg_dump mirror 를 남길지 여부 결정 (§16 후속 "외장 SSD R2 mirror")
  - 옵션 (ii) **즉시 삭제**: archive 용이라면 R2 `archive-*` prefix 로 이미 복사됨 → `kubectl -n apps delete pvc postgresql-backups-ssd` + 외장 SSD 디렉토리 수동 정리
  - v0.4 권장: (i) 유지, 4주 관찰 후 § 16 후속에서 재결정

#### Phase 8.5 — 주변 코드 정리
- [ ] `backup.sh` 포스트그레스 관련 블록 제거
- [ ] `.github/renovate.json` 의 `postgres-backup` 이미지 자동 업데이트 규칙 검토 — 이미지 빌드 워크플로우 (`build-postgres-backup.yml`) 도 폐기 여부 결정
- [ ] README tech stack 업데이트: Bitnami PostgreSQL 16.x → CloudNativePG + plugin-barman-cloud

#### Phase 8.6 — 검증
- [ ] `helm list -A | grep -i postgres` 0건
- [ ] `kubectl get all,pvc -A | grep -iE "^apps.*postgres"` 결과에 CNPG 외 Bitnami 잔존 0건
- [ ] Grafana "Bitnami postgres" 패널 / 알람 모두 비활성화 (있다면)
- [ ] 30일 관찰: 숨은 참조로 인한 장애 없음 확인

### Phase 9 — 문서화 & 안정화 (1–2일)

- [ ] Runbook 5종 (v0.4 리뷰 C2: PITR 드라이런 두 시나리오 분리):
  - `cnpg-new-project.md` — 신규 프로젝트 DB 추가
  - `cnpg-pitr-restore.md` — **동일 namespace 시점복구** (§8.2 5단계 PR 흐름, 평시 사고 대응)
  - `cnpg-dr-new-namespace.md` — **별도 namespace 복구** (DR/감사용 시점 스냅샷)
  - `cnpg-upgrade.md` — CNPG operator + postgres major upgrade
  - `cnpg-webhook-deadlock-escape.md` — M3 비상 절차
- [ ] `docs/disaster-recovery.md` DB 섹션 업데이트
- [ ] README tech stack·backup strategy 테이블 갱신
- [ ] 30일 관찰 (알람 false positive, 실사용 메모리)

**L8 반영 · Phase 3·5·8 직후 해당 Runbook skeleton(TBD 블록 포함)을 commit**하고 실행 중 메모를 붙여 Phase 9에서 완성.

---

## 13. 리스크 & 완화 (v0.2 추가 항목)

| ID | 리스크 | 심각도 | 완화 |
|---|---|---|---|
| R1 | Operator · plugin major upgrade CRD breaking | 중 | `upgrade-planner` · Renovate major 분리 · Phase 0 버전 pin |
| R2 | Single-node 장애 시 복구 | 중 | 월 1회 PITR 리허설 · R2 백업 무결성 smoke test |
| R3 | Barman in-tree v1.30 제거 | 낮(→중) | **v0.2에서 plugin 선채택으로 완화** |
| R4 | 프로젝트 수 증가 메모리 초과 | 중 | 5 프로젝트 재검토 트리거 |
| R5 | Database CRD alpha/beta | 낮 | v1.26 GA 확인 |
| R6 | Bitnami 폐기 시 숨은 참조 | 낮 | grep + kubectl + 7일 suspend 완충 |
| R7 | SealedSecret 재seal 자동화 복잡 | 중 | Phase 0 D-4로 방법론 확정 · namespace-scoped 정책 |
| R8 | webhook deadlock | 중 | M3 escape Runbook |
| R9 | Large ConfigMap SSA 이슈 | 낮 | CNPG 리소스 크기 사전 확인 |
| R10 | ArgoCD selfHeal vs operator auto-manage 충돌 | 중 | operator 관리 필드를 Git 매니페스트에 포함하지 않기 |
| R11 | **cert-manager 미설치 상태에서 plugin 설치** | 중 | Phase 1 순서 강제 · ArgoCD syncWave -3 → -2 → -1 |
| R12 | **Plugin agent 장애 시 WAL archive 멈춤** | 중 | Plugin pod health 모니터링 알람 추가 · 수동 Backup escape |
| R13 | **kubeseal cert endpoint 접근 불가** | 낮 | Phase 0 D-4 · 대체: 외부 seal → git commit |
| R14 | **R2 single source backup 실패** | 낮(→중) | **R2 Bucket Lock (prefix 기반 retention, I-7 결과)** + R2 lifecycle · 외장 SSD mirror (§16 후속) · 이기종 B2/Glacier 이중화 (v2.0). R2 bucket versioning 은 미지원 확정 — 의존 금지 |
| R15 | **Bitnami drift 로 인한 Phase 8 복잡도 상승 (v0.4 신규, A1)** | 중 | I-0 팩트체크 완료 · Phase 8 에서 `helm uninstall` 선행 · 실사용 0 이므로 데이터 손실 리스크 없음 |
| R16 | **Renovate 자동 업그레이드로 의도치 않은 primary pod 재시작 (v0.4 신규, H6)** | 중 | packageRules 에 `cnpg-stack` 그룹 auto-merge 금지 + dependencyDashboardApproval 필수 |
| R17 | **Database CRD GA 선언 부재 (v0.4 신규, H2)** | **매우 낮** (I-2a 조사 후 하향) | v1.25 도입 이후 1.5년간 breaking change 0건, v1 API group, 공식 docs 에 experimental 표기 없음 — 사실상 stable 취급. sync wave 분리 + `databaseReclaimPolicy: retain` 명시로 커버 |
| R18 | **ArgoCD Kustomize+Helm inline 렌더 설정 누락 (v0.4 신규, C3)** | 중 | Phase 0 D-5 결정 · Phase 1.0 선행 PR 로 argocd-cm 변경 or multi-source 분리 |

---

## 14. 롤백 플랜 (v0.4 리뷰 P1 확장 — 진입 전/진행 중/완료 후 분리)

**원칙**: 롤백 비용은 Phase 의 시점에 따라 극적으로 변한다. "단일 명령" 표현은 완료 후 데이터 영향을 감춘다. 각 Phase 별 3단계로 분리 명시:

| Phase | 진입 전 rollback | 진행 중 rollback | 완료 후 rollback | 데이터 영향 |
|---|---|---|---|---|
| 0 (Investigation) | 무비용 | 무비용 (문서만) | 무비용 | 0 |
| 1 (cert-manager) | 무비용 | `argocd app delete cert-manager --cascade` (5분) + CRD 제거 (5분) | 동일. `crds.keep: true` 로 CRD 자동 보존 (리뷰 C5 반영) | 0 |
| 2 (operator+plugin) | 무비용 | 동일. AppProject whitelist revert 필요 | 동일. **Cluster CR 이 있으면 cascade 중 finalizer block 위험** (M3 escape 필요). Phase 2 완료 시점엔 Cluster 0 개이므로 안전 | 0 |
| 3 (PoC) | 무비용 | `kubectl delete ns pg-trial` | PVC reclaim Delete → local-path 데이터 소거. PoC 데이터 가치 0 | **PoC 데이터 손실** (가치 0) |
| 4 (backup) | 무비용 | ScheduledBackup·Backup·ObjectStore 삭제 + R2 prefix 비우기 | **`backupOwnerReference: cluster` (H5/C4) 로 변경 후**: ScheduledBackup 변경 시 Backup CR 이력 유지. Cluster 삭제 시에만 cascade. R2 archive prefix 는 lifecycle 비적용 — 수동 정리 필요 | R2 객체 소거 가능 (원본은 DB 에 살아있으면 재생성 가능) |
| 5 (monitor) | 무비용 | git revert + argocd sync | 동일 | 0 |
| 6 (first project) | 무비용 | Application 삭제 + namespace 삭제 | **High risk** — 실 데이터 있는 namespace 삭제 = PVC Delete = local-path 영구 손실. **사전 R2 backup 무결성 검증 필수** | 프로덕션 데이터 영구 손실 위험 |
| 7 (automation) | 무비용 | `.github/actions/setup-app/database/` git rm + workflow revert | 동일 | 0 (매니페스트만) |
| 8 (Bitnami 폐기) | Task 8.0 까지 rollback 가능 | **Task 8.3 helm uninstall 이후 불가** (단 Task 8.4 Step 0 의 Retain patch 로 PV 30일 보존 가능, 리뷰 H6) | **불가 영구** | data-postgresql-0 데이터 영구 손실 (실사용 0 가정) |
| 9 (docs/30d) | 무비용 | git revert | 동일 | 0 |

**Critical Gate**:
- Phase 6 진입 전: R2 backup 무결성 검증 스크립트 (Task 4.4 + dr-verification 스킬) 1회 이상 통과
- Phase 8 진입 전: 10개 사전 조건 체크리스트 (Task 8.0 Step 3, 리뷰 H6) **모두 ✅**
- Phase 8 Task 8.3 직전: 운영자 명시적 yes prompt + `_workspace/cnpg-migration/17_final-backup-integrity.md` 박제 완료

---

## 15. 성공 기준

- [ ] CNPG operator + plugin + cert-manager 30일 무장애
- [ ] PITR 드라이런 3회 성공 (Phase 4·6·9)
- [ ] setup-app 실행 → 5분 이내 DB ready, 앱이 쓰기 가능
- [ ] 시나리오-1·2 모두 end-to-end 동작
- [ ] 알람 4종 실존 메트릭 기반 · 테스트 발화 1회 성공 (state 오염 없음)
- [ ] Bitnami 관련 클러스터 리소스 0개
- [ ] Runbook 4종 + disaster-recovery 업데이트
- [ ] 총 메모리 OrbStack 할당의 70% 미만 유지

---

## 16. Out of Scope

- Connection pooler (`Pooler` CRD · pgbouncer)
- 논리 복제 (`Publication` · `Subscription`)
- 세밀한 role 관리 (readonly user · RLS)
- CNPG cluster-to-cluster replication
- PostgreSQL 17 major upgrade
- 앱 레벨 ORM/migration 도구 표준
- Cilium CNI 전환 (FQDN egress 통제)
- **백업 무결성 자동 검증 CronJob (L9 제안 → 리뷰 P5: priority 상향)**: Phase 9 안정화 중 조기 도입 검토. 월 1회 `pg_restore --list` 자동 실행 + Grafana 알람 (리뷰 P5 반영).
- **외장 SSD R2 mirror 이중화 (M7 완화 후속)**
- **Incremental backup 정책 (v0.4 리뷰 M6 신규)**: barman-cloud plugin 의 incremental backup 을 활용하여 base backup 주기 (현재 매일) 를 주간으로 확장 + 일일 incremental. R2 저장 공간 절감 · base 복원 시간 단축. v1.0 은 `method: plugin` + default `type: full` 유지, v1.1 후속 도입 검토.
- **StorageClass 전환 — OpenEBS LocalPV Hostpath** (잔여 TODO · **CNPG Phase 9 완료 직후 실행 확정**) → [docs/plans/2026-04-20-openebs-localpv-migration-followup.md](2026-04-20-openebs-localpv-migration-followup.md)

---

## 17. 오픈 퀘스천 (v0.3 확정)

모든 항목 **확정**. v0.2 기본 제안을 그대로 채택.

| # | 질문 | 확정 답 |
|---|---|---|
| Q1 | Cluster 전략 | 프로젝트별 전용 Cluster |
| Q2 | Postgres 버전 | 16 (LTS, EOL 2028-11) |
| Q3 | Backup 방식 | **Plugin (barman-cloud + ObjectStore CR)** |
| Q4 | Storage 전략 | 통합 6Gi (data+WAL) |
| Q5 | TLS sslmode | `require` (CA 미마운트) |
| Q6 | SealedSecret scope | namespace-scoped |
| Q7 | Role password 제공 방식 | 사용자가 SealedSecret 선제 생성 → `managed.roles[].passwordSecret` 참조 |
| Q8 | Connection 주입 | 명시 `secretKeyRef` + 정적 env + `DATABASE_URL` 조합 |
| Q9 | Backup retention | 14일 |
| Q10 | Operator namespace | `cnpg-system` (plugin 동일 namespace) |
| Q11 | `.app-config.yml` 하위호환 | `database.enabled: false` 기본 → 기존 앱 영향 없음 |
| Q12 | 테스트 프로젝트 | `pg-trial` (PoC) → 실제 신규 프로젝트 순차 |
| Q13 | cert-manager 신규 도입 | **YES** · Phase 1 필수 선행 |
| Q14 | kubeseal cert endpoint | **ARC runner in-cluster** → `sealed-secrets-controller` Service 직접 호출 |
| Q15 | R2 backup 이중화 | §16 후속. v1.0은 bucket versioning + retention lock만 |

**결정 컨텍스트**: 6개월 내 DB 사용 앱 확정 → 골든 타이밍에 Plugin 풀세트 진행 (YAGNI 통과).

---

## 18. 다음 스텝

1. **본 문서 v0.2 검토** → Q1–Q15 답변 (특히 Q3·Q13·Q14 blocking)
2. v0.3 revision (답변 반영)
3. `writing-plans` 스킬로 Phase 0–9 실행 플랜 생성 (파일 단위 diff, 커밋 분할, 검증 커맨드)
4. Phase 0부터 순차 실행

---

## Appendix A. 매니페스트 스켈레톤 (v0.2 전면 개편)

### A.1 `manifests/infra/cert-manager/` (multi-source 레이아웃, v0.4 D-5 (b) 확정)

> **v0.4 리뷰 C1 반영**: helmCharts 인라인 블록 → multi-source Application 패턴. traefik 전례 재사용.

디렉토리 구성:
```
manifests/infra/cert-manager/
├── kustomization.yaml    # overlay (namespace + 향후 ClusterIssuer)
├── namespace.yaml
└── values.yaml           # ArgoCD Application sources[0].helm.valueFiles 참조 대상
```

`kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cert-manager
resources:
  - namespace.yaml
  # 향후 ClusterIssuer, Certificate 등 추가
```

`values.yaml` (v0.4 리뷰 C5 반영 — cert-manager v1.15+ 신 키):
```yaml
crds:
  enabled: true    # v1.15+ 신 스키마 (구 `installCRDs: true` deprecated · v1.16+ 일부 ignored)
  keep: true       # helm uninstall 시 CRD 잔존 (PV 유사 안전장치, Certificate/Issuer 보존)
resources:
  requests: { cpu: 50m, memory: 64Mi }
webhook:
  resources: { requests: { cpu: 10m, memory: 32Mi } }
cainjector:
  resources: { requests: { cpu: 10m, memory: 32Mi } }
prometheus:
  enabled: false
```

ArgoCD Application `spec` 요지 (Task 1.3 전체 YAML 은 plan 참조):
```yaml
spec:
  project: infra
  sources:
    - chart: cert-manager
      repoURL: https://charts.jetstack.io
      targetRevision: "<PIN_IN_PHASE_0>"
      helm:
        valueFiles:
          - $values/manifests/infra/cert-manager/values.yaml
    - repoURL: https://github.com/ukkiee-dev/homelab.git
      targetRevision: main
      path: manifests/infra/cert-manager
      ref: values
```

> Phase 0 Task 0.2 Step 3 에서 `helm show values` 덤프로 현재 pin 된 chart 버전의 실제 스키마 확인. v1.14 이하라면 `installCRDs` 사용 (신 스키마 미지원).

### A.2 `manifests/infra/cnpg-operator/` (multi-source 레이아웃, v0.4 D-5 (b) 확정)

> **v0.4 리뷰 C1 반영**: §A.1 과 동일 패턴. helmCharts 인라인 폐기.

디렉토리 구성:
```
manifests/infra/cnpg-operator/
├── kustomization.yaml    # overlay (namespace + 향후 metrics-service.yaml 리뷰 C3 대응)
├── namespace.yaml
└── values.yaml           # Alloy 직접 scrape 전제로 PodMonitor 비활성화
```

`kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cnpg-system
resources:
  - namespace.yaml
  # 리뷰 C3 대응: Helm chart 가 operator 메트릭 Service 자동 생성 안 할 경우 여기 metrics-service.yaml 추가
```

ArgoCD Application `spec` 요지 (Task 2.3 전체 YAML 은 plan 참조):
```yaml
spec:
  project: infra
  sources:
    - chart: cloudnative-pg
      repoURL: https://cloudnative-pg.github.io/charts
      targetRevision: "<PIN_IN_PHASE_0>"
      helm:
        valueFiles:
          - $values/manifests/infra/cnpg-operator/values.yaml
    - repoURL: https://github.com/ukkiee-dev/homelab.git
      targetRevision: main
      path: manifests/infra/cnpg-operator
      ref: values
```

**L2 반영 (v0.4 C3 → 리뷰 C1 갱신)**: D-5 는 (b) multi-source 로 **확정**. argocd-cm 전역 `--enable-helm` 플래그는 사용하지 않는다 (blast radius 회피). Phase 1.0 은 "회귀 테스트" → "multi-source 스캐폴딩 준비" 로 scope 변경.

### A.3 `manifests/infra/cnpg-barman-plugin/`

```yaml
# Application source: upstream release manifest
# https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/<VER>/manifest.yaml
# 버전 pin Phase 0에서
```

### A.4 Role Password SealedSecret (사용자 수동 생성)

```yaml
apiVersion: v1
kind: Secret
type: kubernetes.io/basic-auth
metadata:
  name: pokopia-wiki-pg-api-credentials
  namespace: pokopia-wiki
  labels:
    cnpg.io/reload: "true"
stringData:
  username: api
  password: <generated>
```
→ `kubeseal < /tmp/secret.yaml > common/role-secrets.sealed.yaml` (append) 후 git commit.

### A.5 Cluster CR

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pokopia-wiki-pg
  namespace: pokopia-wiki
  annotations:
    argocd.argoproj.io/sync-wave: "0"
  labels:
    app.kubernetes.io/name: pokopia-wiki-pg
    app.kubernetes.io/component: database
    app.kubernetes.io/part-of: pokopia-wiki        # L3 반영
    app.kubernetes.io/managed-by: argocd
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:<PIN_IN_PHASE_0>  # v0.4 M1: Phase 0 I-2 에서 확정
  primaryUpdateStrategy: unsupervised   # single-instance minor 업그레이드 무인 재시작 (v0.4 H6: Renovate auto-merge 금지 전제)
  storage:
    size: 5Gi                           # default (D 시나리오). .app-config.yml database.storage 로 override
    storageClass: local-path
  resources:
    requests: { cpu: 100m, memory: 384Mi }
    limits:   { cpu: 1000m, memory: 1Gi }
  monitoring:
    enablePodMonitor: false             # Alloy 직접 scrape
  managed:
    roles:
      - name: api
        ensure: present
        login: true
        passwordSecret:
          name: pokopia-wiki-pg-api-credentials
      # 시나리오-2라면 여기 scraper role 추가
      # - name: scraper
      #   ensure: present
      #   login: true
      #   passwordSecret:
      #     name: pokopia-wiki-pg-scraper-credentials
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: pokopia-wiki-backup
        serverName: pokopia-wiki-pg
```

### A.6 ObjectStore CR

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: pokopia-wiki-backup
  namespace: pokopia-wiki
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  configuration:
    destinationPath: s3://homelab-db-backups/pokopia-wiki
    endpointURL: https://<ACCOUNT_ID>.r2.cloudflarestorage.com
    s3Credentials:
      accessKeyId:     { name: r2-pg-backup, key: ACCESS_KEY_ID }
      secretAccessKey: { name: r2-pg-backup, key: SECRET_ACCESS_KEY }
    wal:  { compression: gzip }
    data: { compression: gzip }
  retentionPolicy: "14d"
```

### A.7 ScheduledBackup CR

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: pokopia-wiki-pg-daily
  namespace: pokopia-wiki
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  schedule: "0 0 18 * * *"              # UTC 18:00 = KST 03:00
  cluster: { name: pokopia-wiki-pg }
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  backupOwnerReference: cluster         # v0.4 H5: audit trail 보존
```

### A.8 Database CR (시나리오별)

```yaml
# 시나리오-1 공유: common/database-shared.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: wiki
  namespace: pokopia-wiki
  annotations: { argocd.argoproj.io/sync-wave: "1" }
spec:
  cluster: { name: pokopia-wiki-pg }
  name: wiki
  owner: wiki
  databaseReclaimPolicy: retain         # v0.4 I-2a: ArgoCD prune 방어, 기본값 명시적 박제

# 시나리오-2 분리: services/api/database.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: api
  namespace: pokopia-wiki
  annotations: { argocd.argoproj.io/sync-wave: "1" }
spec:
  cluster: { name: pokopia-wiki-pg }
  name: api
  owner: api                            # managed.roles에 api가 있어야 함
  databaseReclaimPolicy: retain         # v0.4 I-2a: prune 시 실 DB 는 drop 안 함
```

**L4 반영**: 템플릿에서 `spec.name = metadata.name` 자동 동기 (setup-app composite action의 yq 로직에서 보장).

### A.9 Deployment envs (발췌)

```yaml
spec:
  template:
    spec:
      containers:
        - name: api
          image: ghcr.io/ukkiee-dev/pokopia-wiki-api:<tag>
          env:
            - name: POSTGRES_HOST
              value: pokopia-wiki-pg-rw
            - name: POSTGRES_PORT
              value: "5432"
            - name: POSTGRES_DB
              value: api
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: pokopia-wiki-pg-api-credentials
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: pokopia-wiki-pg-api-credentials
                  key: password
            - name: DATABASE_URL
              value: postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_HOST):$(POSTGRES_PORT)/$(POSTGRES_DB)?sslmode=require
```

---

## Appendix B. 메모리·제약 체크리스트 (v0.4 리뷰 P3 전면 갱신)

사용자 메모리 13건 전체에 대한 본 설계의 반영 상태:

- [x] **ArgoCD 변경은 Git 먼저** (`feedback_argocd_changes`) — selfHeal 주의 · §8.2 PITR 절차 Git PR 경유
- [x] **Helm + ArgoCD ownership conflict** (`feedback_helm_argocd_conflict`) — operator 관리 영역 수동 수정 금지 · §D12 sync-options 표준
- [x] **AppProject cluster resource 차단** (`project_argocd_appproject_cluster_resources`) — Phase 2 선제 whitelist 업데이트 · v0.4 H1 apps AppProject 도 사전 점검 (리뷰)
- [x] **ArgoCD multi-source 교착** (`project_argocd_multisource_deadlock`) — D-5 (b) multi-source 채택 시 traefik 전례만 따라감 · sources[] 배열 순서 고정 주의 (Task 1.0 Step 2)
- [x] **알람 YAML ≠ 동작 검증** (`feedback_alert_metric_verification`) — Phase 3 Task 3.8 메트릭 dump + Phase 5 PromQL 실존 검증 · 라벨 키도 dump (M8) · 리뷰 H5 라벨 매칭
- [x] **K3s 시스템 메모리 ~2.3Gi** (`project_k3s_system_memory`) — OrbStack 12Gi 설정 · §11.2 5 프로젝트 안전선
- [x] **리소스 right-sizing 피크24h × 1.3** (`project_resource_sizing`) — Phase 5 이후 실사용 기반 재조정 (§D15)
- [x] **큰 ConfigMap SSA 우회** (`project_argocd_large_configmap_ssa`) — sync-options 표준 적용 (§D12)
- [x] **ArgoCD Helm metrics Service 누락** (`project_argocd_metrics_service_gap`) — Phase 0 Task 0.2 Step 3 operator 메트릭 Service 키 검증 + Phase 5 Task 5.1.1 조건부 수동 Service 추가 (리뷰 C3)
- [x] **Traefik 34→39 GOMEMLIMIT SSA 충돌** (`project_traefik_helm_v39_gomemlimit_ssa`) — ArgoCD Application `ignoreDifferences` 패턴 (Phase 6 Task 6.3, 리뷰 P7). CNPG Cluster CR 에 operator default 자동 채움 drift 예상 시 선제 적용
- [x] **AdGuard Home + Tailscale DNS** (`project_adguard_tailscale_dns`) — CNPG 범위 밖, 회귀 영향 없음 (Phase 1.4 Traefik ACME 격리 검증과 유사하게 Phase 5 에서 DNS 경로 회귀 확인)
- [x] **외장 SSD 접근 제약** (`project_external_ssd_access`) — Task 8.0 Step 3 (리뷰 H6) dump 파일 보관용 `/Volumes/ukkiee/backups/cnpg-phase8/`. Pod 경유 쓰기 원칙 유지
- [x] **Cloudflare provider v5 migration gotcha** (`project_cloudflare_v5_migration`) — Task 0.5 Step 5 (리뷰 H3) Terraform `cloudflare_r2_bucket_lock` 은 provider v5.4+ 필요, `terraform plan` 결과 기반 HCL 맞춤. moved block 거부·DNS state rm+import 패턴 주의

**Startup reload burst false positive** (`feedback_alert_startup_burst`) 은 Traefik reload 알람 전용 — CNPG 알람에는 `process_start_time_seconds` grace period 무관 (DB 는 reload 없음). 다만 Phase 5 Task 5.4 의 CNPG 알람도 `for: 5m` 등 grace period 적용 권장.

---

## Appendix C. CNPG 메트릭·API 레퍼런스 스냅샷 (Phase 0 I-1에서 기록)

> Phase 0에서 테스트 Cluster 1회 띄워 아래 커맨드 출력을 박제한다.

### C.1 `/metrics` 덤프 (Phase 0 I-1 결과)

```
<TBD: curl http://<test-cluster-pod>:9187/metrics | grep ^cnpg_>
```

### C.2 `kubectl explain cluster.spec.managed.roles`

```
<TBD: kubectl explain cluster.spec.managed.roles --recursive | head -80>
```

### C.3 `kubectl cnpg plugin status <cluster>` (Phase 2 이후)

```
<TBD>
```

### C.4 CNPG 공식 Grafana dashboard ID

```
<TBD: Phase 0 I-3 결과>
```

---

## Appendix D. v0.1 → v0.2 변경 요약

| 항목 | v0.1 | v0.2 | 근거 |
|---|---|---|---|
| Backup 방식 | in-tree `barmanObjectStore` | **plugin-barman-cloud + ObjectStore CR** | 리뷰 C3 · CNPG v1.30 제거 |
| cert-manager | 언급 없음 | **Phase 1 필수 설치** | Plugin의 gRPC mTLS 의존 |
| Role 관리 | "Database CRD가 자동 생성" | `managed.roles[] + 사용자 SealedSecret` | 리뷰 C1 · 공식 문서 교차확인 |
| Secret 규약 | `<cluster>-<db>` 자동 | `<cluster>-<role>-credentials` 수동 | 리뷰 C1 |
| 알람 메트릭 | `cnpg_collector_last_backup_successful_seconds` 등 추정 | `cnpg_collector_last_available_backup_timestamp` 등 실존 | 리뷰 C2 · 공식 monitoring docs |
| 모니터링 수집 | `enablePodMonitor: true` | `false` + Alloy kubernetes_sd_configs | 리뷰 H10 |
| WAL storage | 1Gi 별도 PVC | data+WAL 통합 6Gi | 리뷰 H6 |
| Cluster limits | 512Mi | 1Gi | 리뷰 H7 |
| ScheduledBackup cron | `"0 0 3 * * *"` (KST 혼동) | `"0 0 18 * * *"` (UTC, 명시적 주석) | 리뷰 H2 |
| ArgoCD sync-options | 명시 없음 | ServerSideApply · Replace · SkipDryRun 표준 | 리뷰 H5 |
| NetworkPolicy | "정교한 egress 제어" | "R2 egress는 HTTPS/443 전체 허용, FQDN 통제 불가" 솔직 기록 | 리뷰 H3 · K3s flannel 한계 |
| SealedSecret scope | cluster-wide 권장 | **namespace-scoped** + seal 자동화 | 리뷰 M2 · blast radius |
| PITR rename 절차 | "Cluster를 rename" | "Cluster 삭제 후 동명 재생성 + app rolling restart" | 리뷰 M1 · metadata.name immutable |
| Webhook deadlock | 언급 없음 | escape 절차 (operator scale 0) Runbook | 리뷰 M3 |
| 알람 테스트 | "임계값 하향 발화" | 임시 규칙 or silence 활용 | 리뷰 M4 |
| PVC resize | 언급 없음 | local-path 미지원 명시 + snapshot 절차 | 리뷰 M5 |
| backupOwnerReference | 미설명 | `self` 의미 명시 · GC 영향 주의 | 리뷰 M6 |
| R2 이중화 | 언급 없음 | §8.4 리스크 인정 + §16 후속 | 리뷰 M7 |
| TLS 구현 | `sslmode=require` 권장만 | verify-full 절차 Runbook 예정 | 리뷰 M8 |
| `.app-config.yml` 호환 | "영향 없음" | **파서 diff 검사를 Phase 7에 추가** | 리뷰 M9 |
| Renovate | 언급 없음 | Phase 7에 packageRules 추가 | 리뷰 M10 |
| Phase 0 구성 | 8개 혼합 체크리스트 | Decision/Investigation/Action 3-카테고리 blocking gate | 리뷰 L5 |
| Appendix C | 없음 | "메트릭·API 스냅샷" 박제 자리 신설 | 리뷰 L6 |
| sync-wave annotation | 예시 누락 | 매니페스트 예시에 포함 | 리뷰 L7 |
| Runbook 작성 시점 | Phase 8 일괄 | Phase 3·5·8 직후 skeleton commit, Phase 9 완성 | 리뷰 L8 |
| 백업 무결성 자동 검증 | 없음 | §16 후속 항목 추가 | 리뷰 L9 |

**미반영 항목**: H1 (`primaryUpdateStrategy: unsupervised`) — 완전 no-op이 아니라 minor 업그레이드 무인 재시작 제어 목적. 주석으로 의도 명시하고 유지 (reviewer 제안과 절충).

---

*End of design doc v0.2*
