# CloudNativePG Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Bitnami PostgreSQL Helm chart을 CloudNativePG operator + barman-cloud plugin 기반 선언형 관리 체계로 교체하고, 모노레포 프로젝트별 전용 Cluster 및 setup-app 자동화까지 구축한다.

**Architecture:** cert-manager (신규 infra) → CNPG operator → plugin-barman-cloud (3-layer) + 프로젝트별 namespace에 `Cluster` + `ObjectStore` + `Database` CRD + 사용자가 선제 생성한 SealedSecret 기반 `managed.roles`. 앱은 정적 env + `secretKeyRef`로 연결.

**Tech Stack:** K3s on OrbStack · ArgoCD · Helm · CNPG v1.29.x · cert-manager v1.x · plugin-barman-cloud v0.12.x · SealedSecrets · Kustomize · yq · kubeseal · Alloy · VictoriaMetrics

**Reference Design:** @docs/plans/2026-04-20-cloudnativepg-migration-design.md (**v0.4** — design-review v0.3 반영: C1/C2/C3, H1~H6, M1~M7, A1)
**Reference Review:** @docs/plans/2026-04-20-cloudnativepg-migration-design-review.md


---

## Plan Index

| Phase | 이름 | 예상 소요 | Blocking? |
|---|---|---|---|
| 0 | Decision + Investigation + Action (gate) | 1–2일 | YES |
| 1 | cert-manager 설치 | 1일 | YES (plugin 전제) |
| 2 | CNPG operator + plugin 설치 | 1–2일 | YES |
| 3 | 첫 Cluster PoC (`pg-trial`) | 1일 | YES |
| 4 | 백업 통합 + PITR 드라이런 | 1–2일 | YES |
| 5 | 모니터링 통합 | 1일 | No |
| 6 | 첫 실제 프로젝트 전환 | 1–2일 | No |
| 7 | setup-app 자동화 확장 | 2–3일 | No |
| 8 | Bitnami 폐기 | 1일 | Phase 6 이후 |
| 9 | 문서화 & 안정화 | 1–2일 | 마지막 |

총 **12–15일** (v0.4 기준 — Phase 0 확장 조사 I-0a/I-2a/I-7 · Phase 1 argocd-cm 분기 · Phase 8 helm uninstall 선행 반영). Phase 0–4는 순차 · Phase 5 이후 일부 parallel 가능.

---

## Global Conventions

- **ArgoCD 변경은 Git 먼저** (selfHeal 원복 회피)
- 커밋 메시지 컨벤션: `<type>(<scope>): <subject>` (feat/fix/docs/chore)
- 매니페스트 파일 편집 후 `kubectl apply --dry-run=server --validate=true -f <file>` 로 로컬 검증 권장
- 모든 SealedSecret은 namespace-scoped (cluster-wide 금지)
- operator·plugin·cert-manager 버전은 Phase 0 I-2 에서 pin 후 renovate.json 에 packageRules 추가

---

# Phase 0: Decision + Investigation + Action

> **v0.4 갱신**: Blocking gate. **5개 Decision** (D-5 신규) · **8개 Investigation** (I-0a/I-2a/I-7 신규, I-0 pre-verified) · 5개 Action 완료 전 Phase 1 진입 금지.

## Task 0.0: 현재 상태 팩트체크 (I-0, pre-verified)

> **v0.4 신규 · design §12 I-0 결과 박제**. 재실행은 현재 상태 재확인만.

**Files:**
- Create: `_workspace/cnpg-migration/10_current-state-factcheck.md`

**Step 1: Helm release 확인**

Run:
```bash
helm list -n apps | grep -i postgres
```
Expected: `postgresql-18.5.15 (deployed)` — 이것이 Bitnami **v18.3.0** 임을 확인.

**Step 2: 클러스터 리소스 확인**

Run:
```bash
kubectl -n apps get sts,svc,pvc,secret | grep -E "postgres|sh.helm.release.v1.postgres"
```
Expected: `statefulset/postgresql`, `service/postgresql{,-hl,-metrics}`, `pvc/data-postgresql-0`, `secret/sh.helm.release.v1.postgresql.*` 확인.

**Step 3: Git drift 박제**

Run:
```bash
git log --all --oneline -- manifests/apps/postgresql/ | head -10
ls manifests/apps/postgresql/
```
Expected: `backup-cronjob.yaml`, `backup-storage.yaml`, `sealed-secret-r2.yaml` 만 존재 (StatefulSet/Service/PVC 매니페스트 부재 = Git drift 상태).

**Step 4: 결과 박제**

Write `_workspace/cnpg-migration/10_current-state-factcheck.md`:
```markdown
# 현재 상태 팩트체크 (2026-04-20)

## Bitnami Helm release
- name: postgresql / chart: postgresql-18.5.15 / app: 18.3.0
- 설치 방식: `helm install` 직접 (ArgoCD Application 관리 밖)

## 클러스터 리소스 (Bitnami drift)
<kubectl 출력>

## 영향: Phase 8 재설계 (helm uninstall 선행)
```

Commit:
```bash
git add _workspace/cnpg-migration/10_current-state-factcheck.md
git commit -m "docs(cnpg): I-0 factcheck — Bitnami v18.3.0 helm drift"
```

## Task 0.1: Decision 5건 문서화 (D-5 신규)

**Files:**
- Modify: `docs/plans/2026-04-20-cloudnativepg-migration-design.md` — §17 테이블 (이미 v0.3에서 확정됨)
- Create: `_workspace/cnpg-migration/12_kustomize-helm-decision.md` (D-5)

**Step 1: v0.3 design doc §17 확인**

Run: `grep -A 20 "## 17. 오픈 퀘스천" docs/plans/2026-04-20-cloudnativepg-migration-design.md | head -30`
Expected: Q1–Q15 모두 "확정" 표기.

**Step 2: Decision 요약을 이 플랜 하단 체크박스로 기록**

- [x] D-1 Backup 방식 = Plugin (v0.3 확정)
- [x] D-2 cert-manager 신규 도입 YES (v0.3)
- [x] D-3 SealedSecret = namespace-scoped (v0.3)
- [x] D-4 kubeseal cert = ARC runner in-cluster (v0.3)
- [x] **D-5 (v0.4 확정 · 리뷰 C1 반영)** ArgoCD Kustomize+Helm 렌더 전략 = **(b) multi-source Application**
  - 근거: 홈랩 전례 일치 (`argocd/applications/infra/traefik.yaml` 의 `spec.sources[]` 패턴 재사용). argocd-cm 전역 변경의 blast radius 회피. 메모리 `project_argocd_multisource_deadlock` 주의사항은 "source 배열 내 Git 의 `ref` 와 valueFiles 매칭"에 한정되므로 traefik 에서 이미 검증된 한 chart + 한 Git-values 구조로만 사용.
  - **옵션 (a) 기각**: argocd-cm `kustomize.buildOptions: --enable-helm` 전역 플래그는 모든 Application 렌더 경로에 영향 → 회귀 테스트 부담. 홈랩 `helmCharts` 블록 사용 전례 0건.
  - Phase 1.0 (Task 1.0) 은 선택 분기 삭제, multi-source 스캐폴딩만 실행.
  - 결정 박제: `_workspace/cnpg-migration/12_kustomize-helm-decision.md` 에 옵션 비교표와 기각 사유 기록.

## Task 0.2: CNPG operator·plugin·cert-manager·postgres image 버전 pin (I-2)

**Files:**
- Create: `_workspace/cnpg-migration/00_versions.md`

**Step 1: 최신 stable 태그 수집**

Run:
```bash
# CNPG operator chart
helm repo add cnpg https://cloudnative-pg.github.io/charts 2>/dev/null || true
helm repo update cnpg
helm search repo cnpg/cloudnative-pg --versions | head -5

# cert-manager chart
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update jetstack
helm search repo jetstack/cert-manager --versions | head -5

# plugin-barman-cloud releases
gh release list --repo cloudnative-pg/plugin-barman-cloud --limit 5

# postgres image
gh release list --repo cloudnative-pg/postgres-containers --limit 5 2>/dev/null || \
  echo "Check https://github.com/cloudnative-pg/postgres-containers for latest 16.x tag"
```

**Step 2: 선정 결과를 `_workspace/cnpg-migration/00_versions.md` 에 기록**

포맷:
```markdown
# 버전 pin (2026-04-20 기준)

| 구성요소 | 버전 | 근거 |
|---|---|---|
| CNPG operator | <ver> | release notes: <URL> |
| plugin-barman-cloud | <ver> | release notes: <URL> |
| cert-manager | <ver> | release notes: <URL> |
| postgres image | ghcr.io/cloudnative-pg/postgresql:<tag> | ... |
```

**Step 3: Helm chart values schema 덤프**

```bash
# 확정 버전 변수 (00_versions.md 에서 복사)
CNPG_VER="<확정>"
CM_VER="<확정>"

helm repo update cnpg jetstack
helm show values cnpg/cloudnative-pg --version "$CNPG_VER" \
  > _workspace/cnpg-migration/08_cnpg-chart-values.yaml
helm show values jetstack/cert-manager --version "$CM_VER" \
  > _workspace/cnpg-migration/08_certmanager-chart-values.yaml

# 핵심 키 구조 확인 (Task 1.1·2.1 values.yaml 작성 전 필수)
# 리뷰 C3 반영: monitoring 하위 전체를 보고 Service 생성 키 식별 (podMonitor/serviceMonitor/service)
yq '.monitoring' _workspace/cnpg-migration/08_cnpg-chart-values.yaml
yq '.resources, .crds' _workspace/cnpg-migration/08_cnpg-chart-values.yaml

# 리뷰 C5 반영: cert-manager v1.15+ 에서 installCRDs 는 deprecated, crds.enabled 로 전환.
# crds / webhook / cainjector / prometheus 실제 스키마 확인
yq '.crds, .installCRDs, .webhook, .cainjector, .prometheus' _workspace/cnpg-migration/08_certmanager-chart-values.yaml
```

Expected:
- **CNPG monitoring 블록**: `podMonitor` · `serviceMonitor` · `service` · `grafanaDashboard` 하위 키 목록. Service 자동 생성 여부 판단 — 메모리 `project_argocd_metrics_service_gap` 패턴(`.metrics.enabled=true` 만으로 Service 안 만들어지는 경우) 이 CNPG operator chart 에서도 재현되는지 확인. Service 생성 키가 없거나 비활성이면 **Phase 5 Task 5.1.1 (metrics-service kustomize patch)** 추가 필요. 박제: `_workspace/cnpg-migration/08_cnpg-chart-values.yaml`.
- **cert-manager crds 블록**: v1.15+ 신 스키마는 `crds.enabled` · `crds.keep`. 구 스키마 (`installCRDs`) 가 여전히 최상위 키로 보이면 해당 chart 버전은 v1.14 이하 → 신 스키마로 쓰고 싶으면 upgrade 필요. 박제: `_workspace/cnpg-migration/08_certmanager-chart-values.yaml`.
- 내가 plan에 쓴 예시 키 이름(`monitoring.podMonitorEnabled`, `crds.create`, `installCRDs` 등)은 **실제 스키마와 다를 수 있음** — 반드시 덤프 기준으로 values.yaml 작성.

**Step 4: 커밋**

Run:
```bash
git add _workspace/cnpg-migration/00_versions.md _workspace/cnpg-migration/08_*.yaml
git commit -m "chore(cnpg): pin component versions + capture chart values schema"
```

## Task 0.3: Grafana dashboard ID 확인 (I-3)

**Files:**
- Modify: `_workspace/cnpg-migration/00_versions.md` (dashboard 섹션 추가)

**Step 1: 공식 대시보드 확인**

Run: `open "https://grafana.com/grafana/dashboards/?search=cloudnative-pg"`
(또는 WebFetch) 공식 CNPG dashboard ID 확정.

**Step 2: VictoriaMetrics 데이터소스 호환성 확인**

Run:
```bash
kubectl -n monitoring get svc -l app=victoria-metrics-single
```
Dashboard의 Prometheus 쿼리가 VM-compatible인지 개요 확인 (PromQL은 호환, 일부 `topk` 등은 지원).

**Step 3: `00_versions.md` 에 ID 기록 + 커밋**

## Task 0.4: 클러스터 baseline 실측 (I-4, I-5)

**Files:**
- Create: `_workspace/cnpg-migration/01_baseline.md`

**Step 1: 노드·namespace 메모리 실측**

Run:
```bash
kubectl top node --no-headers
kubectl top pod --all-namespaces --sort-by=memory | head -30
```

**Step 2: VM PromQL로 namespace 총합**

Run:
```bash
# Grafana Explore 또는 직접 VM API
curl -s "http://<vm-svc>:8428/api/v1/query?query=sum(container_memory_working_set_bytes{namespace!=\"\"})by(namespace)"
```

**Step 3: 결과를 `01_baseline.md` 테이블로 기록**

**Step 4: Alloy config 형식 박제 (v0.4 리뷰 M2 신규)**

Phase 5 Task 5.1 코드 예시를 River 또는 Prometheus YAML 중 하나로 좁히기 위해 기존 Alloy scrape job 1개를 사례로 박제.

```bash
# Alloy ConfigMap/config 파일 위치 확인
grep -rln "prometheus.scrape\|scrape_configs" manifests/monitoring/alloy/ | head -3

# 첫 번째 scrape job 을 발췌해서 01_baseline.md 에 박제
head -60 <Alloy config 파일 경로> > /tmp/alloy-sample.snippet
```

`01_baseline.md` 에 추가:
```markdown
## Alloy config 형식 (Phase 5 Task 5.1 기준)

- 형식: **River** 또는 **Prometheus YAML** (실측 결과)
- 기존 scrape job 예시:
  \`\`\`
  (실제 파일 발췌 — 예: prometheus.scrape "kube_state_metrics" { ... })
  \`\`\`
```

Phase 5 Task 5.1 은 위 형식 하나만 사용 — fallback 예시 제거.

**Step 5: 커밋**

## Task 0.5: R2 버킷 + API 토큰 준비 (A-1)

**Files:** (환경 작업, 저장소 변경 없음)

**Step 1: R2 버킷 생성**

Cloudflare Dashboard → R2 → Create bucket:
- Name: `homelab-db-backups`
- Location: automatic
- Default storage class: Standard

**Step 2: API 토큰 발급 + bash export 포맷으로 저장**

Dashboard → R2 → Manage R2 API Tokens → Create → Permissions: Object Read & Write, Specify bucket: `homelab-db-backups`.

`_workspace/cnpg-migration/02_r2-credentials.txt` (gitignore 필수) 에 **bash export 포맷**으로 저장:

```bash
# _workspace/cnpg-migration/02_r2-credentials.txt
export R2_ACCESS_KEY_ID="xxxxxxxxxxxxxxxxxxxxxxxxxxxx"
export R2_SECRET_ACCESS_KEY="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
export R2_ACCOUNT_ID="xxxxxxxxxxxxxxxx"
export R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
```

이후 Task 0.5 Step 4, Task 4.1, Task 4.6 등이 `source _workspace/cnpg-migration/02_r2-credentials.txt` 로 로드한다.

**주의**: git 절대 커밋 금지 (Step 3에서 gitignore 확인).

**Step 3: `.gitignore` 확인**

Run: `grep -n "_workspace/cnpg-migration/02_r2-credentials.txt" .gitignore || echo "_workspace/cnpg-migration/02_r2-credentials.txt" >> .gitignore`

**Step 4: `curl` 로 R2 smoke test**

Run:
```bash
source _workspace/cnpg-migration/02_r2-credentials.txt
aws --endpoint-url="$R2_ENDPOINT" --region auto \
  s3 ls "s3://homelab-db-backups/"
```
Expected: 빈 버킷 리스팅 성공.

**Step 5: R2 Bucket Lock + lifecycle Terraform 선언 (v0.4 리뷰 H3 신규)**

> **리뷰 H3 반영**: design §8.4 (R14 완화) 가 R2 Bucket Lock (prefix=wal, Age=21d) + lifecycle (base 14d) 을 Terraform 으로 선언한다고 박제했는데, plan 에 실제 Task 가 부재. 이 Step 으로 추가.

**Files:**
- Create: `terraform/r2-pg-backups.tf`
- Modify: `terraform/versions.tf` (cloudflare provider `>= 5.4.0` 확인)

사전 조건:
```bash
# Cloudflare provider 버전 확인
grep -A 3 'cloudflare' terraform/versions.tf
# Expected: version >= "5.4.0" (cloudflare_r2_bucket_lock 지원 최소 버전)
```

`terraform/r2-pg-backups.tf` 스켈레톤:
```hcl
resource "cloudflare_r2_bucket" "pg_backups" {
  account_id = var.cloudflare_account_id
  name       = "homelab-db-backups"
  location   = "WNAM"   # 또는 "APAC" 등 실제 지역
}

# WAL prefix: 21d Age 기반 Bucket Lock (immutable WAL 최소 보호선)
resource "cloudflare_r2_bucket_lock" "wal_retention" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.pg_backups.name

  rules = [
    {
      id      = "wal-min-21d"
      enabled = true
      prefix  = "wal/"
      condition = {
        type = "Age"
        max_age_seconds = 21 * 24 * 3600   # 21d
      }
    }
  ]
}

# base backup prefix: 14d lifecycle (Barman retentionPolicy 14d 와 정합)
resource "cloudflare_r2_bucket_lifecycle" "base_expiry" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.pg_backups.name

  rules = [
    {
      id      = "base-expire-14d"
      enabled = true
      conditions = { prefix = "base/" }
      delete_objects_transition = {
        condition = {
          type = "Age"
          max_age_seconds = 14 * 24 * 3600   # 14d (grace 별도)
        }
      }
    }
  ]
}
```

> 실제 HCL 문법·필드 이름은 `terraform providers schema` 또는 공식 docs 확인 — cloudflare provider v5.x schema 가 필드명을 자주 바꾼다. `terraform plan` 에 의존해서 HCL 맞춰나갈 것.

Commit + plan + apply:
```bash
cd terraform/
terraform plan -target=cloudflare_r2_bucket.pg_backups \
               -target=cloudflare_r2_bucket_lock.wal_retention \
               -target=cloudflare_r2_bucket_lifecycle.base_expiry
# plan 통과 후
terraform apply ...
```

**Step 6: Bucket Lock 활성 확인**

```bash
# S3 API 로는 조회 불가 (R2 독자 기능) → Cloudflare Dashboard UI 확인
# 또는 API 호출
curl -sH "Authorization: Bearer $CF_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/r2/buckets/homelab-db-backups/locks" \
  | jq
```
Expected: `wal-min-21d` rule 활성 상태 표시.

결과 박제: `_workspace/cnpg-migration/14_r2-object-lock.md` 에 Terraform 리소스 이름 · Lock rule id · 적용 일자 기록.

## Task 0.6: OrbStack 메모리 12Gi 확정 (A-2)

**Files:** (환경 작업)

**Step 1: 현재 설정 확인**

Run:
```bash
orbctl info | grep -i memory
kubectl describe node | grep -A 5 "Allocatable"
```

**Step 2: 12Gi 미만이면 상향**

OrbStack UI → Settings → Resources → Memory: 12 GB → Apply.

**Step 3: 재기동 후 확인**

Run:
```bash
orbctl restart
# k3s 재시작 후
kubectl describe node | grep -A 5 "Allocatable" | grep memory
```
Expected: ~11-12Gi allocatable.

## Task 0.7: infra + apps AppProject 3축 diff 준비 (A-3, v0.4 리뷰 H1 확장)

> **리뷰 H1 반영**: v0.3 plan 은 infra AppProject 만 점검. 그러나 Phase 6 이후 실제 프로젝트 (apps 계열) 가 CNPG CR (Cluster/Database/ScheduledBackup/ObjectStore) 을 사용하므로 **apps AppProject 도 namespaceResourceWhitelist 가 화이트리스트 모드이면 `postgresql.cnpg.io/*`, `barmancloud.cnpg.io/*` 등재 필요**. Phase 6 첫 sync 에서 `Resource ... is not permitted in project apps` 에러 회피 목적.

**Files:**
- Create: `_workspace/cnpg-migration/03_appproject-diff.md`

**Step 1: infra AppProject 현재 whitelist 스냅샷**

Run:
```bash
kubectl -n argocd get appproject infra -o yaml | yq '.spec.clusterResourceWhitelist' > /tmp/infra-whitelist.yaml
cat /tmp/infra-whitelist.yaml
```

**Step 1a: apps AppProject 현재 namespaceResourceWhitelist 스냅샷 (v0.4 H1 신규)**

```bash
kubectl -n argocd get appproject apps -o yaml \
  | yq '{namespaceResourceWhitelist: .spec.namespaceResourceWhitelist, sourceRepos: .spec.sourceRepos, destinations: .spec.destinations}' \
  > /tmp/apps-appproject.yaml
cat /tmp/apps-appproject.yaml
```

**판정**:
- `namespaceResourceWhitelist` 가 **없음** (모든 namespace 리소스 허용 모드) → apps 는 그대로 두기, 추가 작업 불필요.
- 있음 (화이트리스트 모드) → `postgresql.cnpg.io/*` · `barmancloud.cnpg.io/*` 추가 필요. **Phase 2.0** (Task 2.2 과 함께) 에서 apps AppProject 도 동시 PR.

**Step 2: CNPG + plugin + cert-manager 용 필요 리소스 목록 작성**

필요한 추가 항목:
```yaml
# CNPG
- group: postgresql.cnpg.io
  kind: "*"
- group: admissionregistration.k8s.io
  kind: ValidatingWebhookConfiguration
- group: admissionregistration.k8s.io
  kind: MutatingWebhookConfiguration
# Plugin
- group: barmancloud.cnpg.io
  kind: "*"
# cert-manager
- group: cert-manager.io
  kind: "*"
- group: acme.cert-manager.io
  kind: "*"
# 공통 (이미 있을 수도)
- group: apiextensions.k8s.io
  kind: CustomResourceDefinition
- group: rbac.authorization.k8s.io
  kind: ClusterRole
- group: rbac.authorization.k8s.io
  kind: ClusterRoleBinding
```

**Step 3: diff 파일 저장**

`_workspace/cnpg-migration/03_appproject-diff.md` 에 현재 vs 목표 diff를 기록. Phase 1–2에서 실제 patch 진행.

## Task 0.8: kubeseal 동작 e2e 검증 (A-5, D-4 확정, v0.4 리뷰 H2 확장)

> **리뷰 H2 반영**: v0.3 plan 은 `--fetch-cert` (public key 획득) 만 검증. 실제 Phase 7 자동화는 "Secret 을 controller 에 보내고 ciphertext 받는" seal 동작 전체가 필요. 로컬·in-cluster 양쪽 모두 e2e 검증하면 Phase 7 디버깅 시 원인 분리 용이.

**Files:** (검증 작업)

**Step 1: 로컬 kubeseal 에서 fetch-cert 확인**

```bash
kubectl -n sealed-secrets get svc sealed-secrets-controller -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}'
kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets-controller \
  --fetch-cert > /tmp/cert.pem
cat /tmp/cert.pem | head -5
```
Expected: PEM 인증서 출력 시작 (`-----BEGIN CERTIFICATE-----`)

**Step 2: 로컬 kubeseal 에서 실제 seal e2e 동작 확인 (v0.4 H2 신규)**

```bash
echo "test-secret-value" | kubectl create secret generic test-seal \
  --dry-run=client --from-literal=key=- -o yaml \
  > /tmp/test-seal.yaml

kubeseal --controller-namespace sealed-secrets \
         --controller-name sealed-secrets-controller \
         --format=yaml \
         < /tmp/test-seal.yaml \
         > /tmp/test-sealed.yaml

# 검증
test -s /tmp/test-sealed.yaml \
  && grep -q "encryptedData:" /tmp/test-sealed.yaml \
  && echo "✅ 로컬 seal 성공" \
  || { echo "❌ 로컬 seal 실패"; exit 1; }

rm /tmp/test-seal.yaml /tmp/test-sealed.yaml
```
Expected: `✅ 로컬 seal 성공`.

**Step 3: ARC runner in-cluster 경로 검증 (v0.4 H2 신규)**

Phase 7 에서 실제 SealedSecret 자동 생성을 수행할 경로 검증.

Option A — 임시 debugging Pod (ARC runner 이미지 계열):
```bash
kubectl -n actions-runner-system run kubeseal-test --rm -it --restart=Never \
  --image=bitnami/sealed-secrets-kubeseal:latest \
  --namespace=actions-runner-system \
  --command -- sh -c '
    echo "test-e2e-value" | kubectl create secret generic test-seal \
      --dry-run=client --from-literal=k=- -o yaml | \
    kubeseal --controller-namespace sealed-secrets \
             --controller-name sealed-secrets-controller \
             --format=yaml \
    | grep -q "encryptedData:" && echo "✅ in-cluster seal 성공" || echo "❌ in-cluster seal 실패"
  '
```

Option B — 실제 GHA workflow 로 검증 (Phase 7 전에 선점):
`.github/workflows/kubeseal-smoke.yml` 생성 (임시):
```yaml
name: Kubeseal Smoke Test
on: workflow_dispatch
jobs:
  smoke:
    runs-on: self-hosted
    steps:
      - run: |
          echo "test" | kubectl create secret generic test --dry-run=client --from-literal=k=- -o yaml | \
          kubeseal --controller-namespace sealed-secrets \
                   --controller-name sealed-secrets-controller \
                   --format=yaml > /tmp/sealed.yaml
          grep -q "encryptedData:" /tmp/sealed.yaml && echo "OK" || exit 1
```
`gh workflow run kubeseal-smoke.yml` 실행 → 성공 확인 후 해당 workflow 파일 제거 (검증 목적 일회성).

Expected: 두 옵션 중 하나라도 성공하면 Phase 7 composite action 작성 시 네트워크·RBAC 경로 문제 배제.

**Step 4: ARC runner NetworkPolicy 상태 점검 (v0.4 리뷰 M5 반영)**

`actions-runner-system` namespace 의 NetworkPolicy 가 `sealed-secrets` (kube-system 또는 별도 namespace) 로의 egress 를 막는지 확인:
```bash
kubectl -n actions-runner-system get networkpolicy
# 결과 있으면 yaml 내용으로 egress 규칙 확인
kubectl -n actions-runner-system get networkpolicy -o yaml \
  | yq '.items[].spec.egress' 2>/dev/null
```
default-deny 가 있는데 sealed-secrets 대상 egress 허용 규칙이 없으면 Phase 7 자동화가 막힐 것 — Phase 7 진입 전 NP 완화 PR 필요.

**Step 5: 결과 기록**

`_workspace/cnpg-migration/04_kubeseal-endpoint.md` 에 4개 Step 결과 + ARC runner 의 NP 상태 + 사용한 debug Pod 이미지 버전 박제. Phase 7 진입 전 체크리스트 참조용.

## Task 0.9: 버전 placeholder 치환 스크립트 준비

**Files:**
- Create: `_workspace/cnpg-migration/09_version-substitutions.sh`

**Step 1: 치환 변수 파일 생성**

Task 0.2 의 `00_versions.md` 확정 버전으로 export:

```bash
cat > _workspace/cnpg-migration/09_version-substitutions.sh <<'EOF'
#!/usr/bin/env bash
# Phase 1-2 매니페스트 작성 후 placeholder 치환용
export CNPG_OPERATOR_VER="<00_versions.md 에서 확정 복사>"
export CNPG_PLUGIN_VER="<확정>"
export CERT_MANAGER_VER="<확정>"
export POSTGRES_IMAGE_TAG="16.<확정>"
# v0.4 리뷰 M3 반영: Task 0.5 의 R2_ACCOUNT_ID 와 변수명 통일.
# ACCOUNT_ID 가 공개 정보 (endpoint URL 에 포함) 라는 점은 별도 주석으로 명시.
export R2_ACCOUNT_ID="<A-1 에서 확보한 account id (공개 가능 · endpoint URL 구성)>"
EOF
chmod +x _workspace/cnpg-migration/09_version-substitutions.sh
```

**Step 2: 매니페스트 치환 헬퍼 함수 문서화**

각 Phase Task 마지막에 적용할 패턴:

```bash
source _workspace/cnpg-migration/09_version-substitutions.sh

# 예시: 단일 파일 치환 (v0.4 리뷰 M3 반영 — 변수명 R2_ACCOUNT_ID 통일)
sed -i.bak \
  -e "s|<PIN_FROM_PHASE_0>|${CERT_MANAGER_VER}|g" \
  -e "s|<POSTGRES_TAG>|${POSTGRES_IMAGE_TAG}|g" \
  -e "s|<ACCOUNT_ID>|${R2_ACCOUNT_ID}|g" \
  "$file"
rm "$file.bak"

# 잔여 placeholder 0개 검증 (v0.4 리뷰 M10 반영 — 더 넓은 패턴)
grep -rn '<PIN\|<POSTGRES\|<ACCOUNT_ID\|<traefik-ns\|<first-project\|<project-pg-app-name' \
     manifests/ argocd/ \
  && { echo "⚠️ 미치환 placeholder 존재"; exit 1; } \
  || echo "✅ 치환 완료"
```

> **v0.4 리뷰 M10 반영**: plan 의 `<traefik-ns>`, `<first-project>`, `<project>` 등 placeholder 가 치환 없이 복사-붙여넣기 되는 실수 방지. `traefik-ns` → `traefik-system` 치환 rule 도 sed 에 추가:
>
> ```bash
> export TRAEFIK_NS="traefik-system"
> sed -i.bak -e "s|<traefik-ns>|${TRAEFIK_NS}|g" "$file"
> ```
>
> `<first-project>` 는 Phase 6 Task 6.1 결정에 따라 주입 — 해당 Task 에서 함께 치환.

**Step 3: 커밋**

```bash
git add _workspace/cnpg-migration/09_version-substitutions.sh
git commit -m "chore(cnpg): add version substitution helper script"
```

> 이후 Phase 1·2 각 Task 마지막 commit 직전에 **placeholder 0건 grep 검증 필수**.

## Task 0.10: local-path-provisioner resize 지원 재확인 (I-6)

> **pre-verified 2026-04-20**: D 시나리오 확정. default 이미 5Gi 로 상향 반영 완료. Phase 0 실행 시 운영 환경에서 **재검증만** 수행하고 Appendix 에 결과 박제.

### 확정된 사실 (2026-04-20 검증 결과)

- StorageClass `local-path`: `allowVolumeExpansion` 필드 **없음**
- provisioner 이미지: `rancher/local-path-provisioner:v0.0.31` (2025-01-24 릴리스)
- 업스트림 Issue #190 "Support Volume Expansion": **OPEN** (2021년부터 미구현)
  - https://github.com/rancher/local-path-provisioner/issues/190
- 사용자 재현 사례 (2024-02): `allowVolumeExpansion: true` 수동 추가 + PVC patch → `waiting for an external controller to expand this PVC` 에서 stuck
- 최근 PR #529 (2025-10) 제출되었으나 미머지
- 결론: **resize 미지원 (D 시나리오)**

### 대응 방침 (이미 반영됨)

- default storage 5Gi 로 pre-set 완료 (Task 3.3·7.4·design doc 전역)
- Phase 9 Runbook: backup → bootstrap.recovery → endpoint swap 절차 작성 예정
- **OpenEBS LocalPV Hostpath 전환 = 본 CNPG 마이그레이션 직후 실행 확정 잔여 TODO** → [2026-04-20-openebs-localpv-migration-followup.md](2026-04-20-openebs-localpv-migration-followup.md)

### Step 1: 운영 환경 재확인 (증거 박제 목적)

Run:
```bash
# StorageClass 에 allowVolumeExpansion 필드 없음 재확인
kubectl get storageclass local-path -o jsonpath='{.allowVolumeExpansion}'
# 예상: 빈 출력 또는 `false`

# Provisioner 이미지 버전
kubectl -n kube-system get deploy local-path-provisioner -o jsonpath='{.spec.template.spec.containers[0].image}'
# 예상: rancher/local-path-provisioner:v0.0.31 또는 이후 버전
```

### Step 2: 업스트림 변경 여부 확인 (버전이 크게 올랐을 때만)

만약 Step 1의 provisioner 이미지 버전이 v0.0.32 이상으로 크게 올랐다면:

```bash
# upstream issue 상태 재확인
gh issue view 190 --repo rancher/local-path-provisioner --json state,title
```

`state: OPEN` 이면 여전히 D 시나리오 유지.
`state: CLOSED` + "COMPLETED" 로 바뀌었으면 재평가 필요 (default 상향 해제 + Runbook 간소화 검토).

### Step 3: 결과 박제

`_workspace/cnpg-migration/11_resize-support.md`:

```markdown
# local-path resize 지원 재확인 (Phase 0 I-6)

- 실행 일자: <YYYY-MM-DD>
- StorageClass allowVolumeExpansion: <값>
- Provisioner 이미지: <버전>
- Issue #190 상태: <OPEN|CLOSED>
- 최종 판정: D 시나리오 (resize 미지원, 2026-04-20 pre-verified 유지)
- 조치: default storage 5Gi 유지 · Runbook backup+restore 절차 · OpenEBS T1 trigger 계속 감시
```

### Step 4: 커밋

```bash
git add _workspace/cnpg-migration/11_resize-support.md
git commit -m "chore(cnpg): phase 0 I-6 re-verify D scenario (local-path resize still unsupported)"
```

## Task 0.11a: Bitnami drift 대응 방침 확정 (I-0a, v0.4 신규)

**Files:**
- Create: `_workspace/cnpg-migration/13_bitnami-drift-decision.md`

**Step 1: 옵션 평가**

Write 문서:
```markdown
# Bitnami drift 대응 방침 (I-0a)

## 사실
- Bitnami postgresql-18.5.15 이 `helm install` 로 apps 네임스페이스에 배포됨
- Git 에 StatefulSet/Service/PVC 매니페스트 없음 (backup 3개만 존재)
- ArgoCD Application `postgresql` 은 backup 3개만 관리 → StatefulSet 은 관리 밖

## 옵션
- (α) **helm uninstall 후 CNPG 교체** — Phase 8 에서 `helm uninstall postgresql -n apps` 선행, 그 후 Application·매니페스트 정리. 실사용 0 으로 데이터 손실 리스크 없음.
- (β) drift 를 Git 으로 박제 후 cascade 삭제 — Bitnami chart 를 정식 Application 으로 등록 후 cascade. 불필요한 우회. 채택 안 함.

## 결정: (α)
Phase 8 절차는 design.md v0.4 §12 Phase 8 참조.
```

Commit:
```bash
git add _workspace/cnpg-migration/13_bitnami-drift-decision.md
git commit -m "docs(cnpg): I-0a bitnami drift decision (helm uninstall path)"
```

## Task 0.11b: Database CRD stability 검증 (I-2a, v0.4 신규)

**Files:**
- Create: `_workspace/cnpg-migration/15_database-crd-stability.md`

**Step 1: CRD stability 확인**

Run (Phase 2 Operator 설치 이후에도 재실행 가능; Phase 0 단계에서는 공식 문서 기반 조사):
```bash
# CNPG 공식 릴리스 노트 확인
gh release list --repo cloudnative-pg/cloudnative-pg --limit 10
# Database CRD stability 관련 이슈·PR 검색
gh search issues --repo cloudnative-pg/cloudnative-pg "Database CRD" --limit 10
```

**Step 2: Phase 2 이후 kubectl explain 재검증**

```bash
kubectl explain database.spec --api-version=postgresql.cnpg.io/v1 --recursive | head -80
```

**Step 3: 결과 박제**

```markdown
# Database CRD stability (I-2a)

- 도입 버전: v1.25
- 현재 상태: <alpha | beta | GA>
- backward-compat 정책: <공식 문서 링크>
- 판정:
  - GA → design §D6 전략 그대로 사용
  - beta → 주의, 하지만 채택 가능
  - alpha → initContainer psql `CREATE DATABASE IF NOT EXISTS` 폴백 병행 고려
```

Commit:
```bash
git add _workspace/cnpg-migration/15_database-crd-stability.md
git commit -m "docs(cnpg): I-2a database CRD stability check"
```

## Task 0.11c: R2 Object Lock 지원 조사 (I-7, v0.4 신규)

**Files:**
- Create: `_workspace/cnpg-migration/14_r2-object-lock.md`

**Step 1: Cloudflare R2 공식 문서 검토**

Check:
- https://developers.cloudflare.com/r2/api/s3/api/ (Object Lock 지원 API 항목 확인)
- Terraform Cloudflare provider `cloudflare_r2_bucket` versioning/lock 속성

**Step 2: barman-cloud 호환성 확인**

Check CNPG plugin-barman-cloud 문서 / Issue 에서 versioned bucket + retentionPolicy 상호작용 확인.

**Step 3: 결과 박제**

```markdown
# R2 Object Lock 지원 조사 (I-7)

- R2 versioning: <Yes/Partial/No> — <근거 링크>
- R2 Object Lock: <GA/Beta/Alpha/Unsupported>
- Terraform provider 지원: <Yes/Partial/No>
- barman-cloud 호환성: <확인 결과>

## 판정
- (a) 모두 지원 → v1.0 에 bucket versioning + Object Lock 적용
- (b) 부분 지원 → v1.0 은 versioning 만, Object Lock 은 §16 후속
- (c) 미지원 → bucket versioning 만, Object Lock 은 외장 SSD mirror 로 대체
```

Commit:
```bash
git add _workspace/cnpg-migration/14_r2-object-lock.md
git commit -m "docs(cnpg): I-7 R2 Object Lock support investigation"
```

## Task 0.12: Phase 0 Go/No-Go 체크

**Step 1: 체크리스트 검토**

아래 모두 ✅ 확인 (v0.4 갱신):
- [x] I-0 현재 상태 팩트체크 (Task 0.0, pre-verified)
- [ ] Decision 5건 — **D-5 포함** (Task 0.1)
- [ ] 버전 pin + Helm values 스키마 덤프 (Task 0.2)
- [ ] Grafana dashboard ID (Task 0.3)
- [ ] Baseline 실측 — Bitnami v18.3.0 메모리 포함 (Task 0.4)
- [ ] R2 버킷·토큰 + bash export 포맷 (Task 0.5)
- [ ] OrbStack 12Gi (Task 0.6)
- [ ] AppProject **3축** diff (Task 0.7, v0.4 확장)
- [ ] kubeseal endpoint 검증 (Task 0.8)
- [ ] 버전 치환 스크립트 (Task 0.9)
- [ ] local-path resize 지원 판정 + default 조정 (Task 0.10)
- [ ] **I-0a Bitnami drift 대응 방침** (Task 0.11a, v0.4 신규)
- [ ] **I-2a Database CRD stability** (Task 0.11b, v0.4 신규)
- [ ] **I-7 R2 Object Lock 지원** (Task 0.11c, v0.4 신규)

**Step 2: 커밋**

Run:
```bash
git add _workspace/cnpg-migration/
git commit -m "docs(cnpg): phase 0 investigation + action artifacts"
```

---

# Phase 1: cert-manager 설치

## Task 1.0: multi-source Application 스캐폴딩 준비 (D-5 확정 · v0.4 리뷰 C1 반영)

> **확정 사항**: Phase 0 D-5 에서 옵션 (b) multi-source 채택. argocd-cm 전역 플래그 변경은 **수행 안 함** (옵션 a 기각). 이 Task 는 traefik 전례를 따라 Helm chart + Git values 이중 source 레이아웃을 scaffold 한다.

**Files:**
- Reference: `argocd/applications/infra/traefik.yaml` (모범 예시)
- 이후 Task 1.1/2.1/2.5 매니페스트 작성 시 이 패턴 적용

**Step 1: 전례 확인 (traefik)**

Run:
```bash
cat argocd/applications/infra/traefik.yaml | sed -n '/^spec:/,/^  destination:/p'
```
Expected: `spec.sources[]` 배열 2개 — `[0]` Helm chart (repoURL + chart + targetRevision + helm.valueFiles with `$values/...`), `[1]` Git repo (repoURL + targetRevision + path + `ref: values`).

**Step 2: 패턴 요약**

```yaml
# 표준 패턴 (cert-manager, cnpg-operator 동일)
spec:
  sources:
    # [0] Helm chart source
    - chart: <chart-name>
      repoURL: https://<helm-repo-url>
      targetRevision: "<PIN_FROM_PHASE_0>"
      helm:
        valueFiles:
          - $values/manifests/infra/<app>/values.yaml    # $values 는 [1] 의 ref
    # [1] Git source — values.yaml 파일 제공 + Kustomize overlay (추가 리소스)
    - repoURL: https://github.com/ukkiee-dev/homelab.git
      targetRevision: main
      path: manifests/infra/<app>                         # Kustomize build 대상
      ref: values                                         # valueFiles 의 $values 참조 식별자
```

**주의 사항 (메모리 `project_argocd_multisource_deadlock` 반영)**:
- `ref: values` 는 반드시 Git source 에만 지정. Helm source 에 `ref` 지정 금지.
- sources 배열 순서 변경 시 source index 가 바뀌어 교착 가능 — 향후 변경 시 Git revert 만으로 복구 안 됨 (kubectl patch 필요). 확정된 순서 고정.
- targetRevision 변경 시에도 동일 주의 — 변경은 Git PR 경유로만.

**Step 3: Kustomize overlay 초기 상태**

Chart 외 추가 리소스가 없는 초기 단계에도 `manifests/infra/<app>/kustomization.yaml` 은 최소 1개 리소스 (namespace.yaml) 를 포함한다. 빈 resources 는 Kustomize build 에러 유발 가능.

**Step 4: D-5 결정 기록**

```bash
cat > _workspace/cnpg-migration/12_kustomize-helm-decision.md <<'EOF'
# ArgoCD Kustomize+Helm 렌더 전략 결정 (D-5)

## 결정: 옵션 (b) multi-source Application

## 근거
- 홈랩 전례: `argocd/applications/infra/traefik.yaml` 이 동일 패턴 사용 (sources[] 2개 — chart + Git values).
- 옵션 (a) argocd-cm 전역 `--enable-helm` 은 모든 Application 렌더 경로 영향 → 회귀 위험.
- 홈랩 `helmCharts` 블록 사용 전례 0건 (`grep -rn "helmCharts" manifests/` 결과 0).

## 적용 대상
- cert-manager (Phase 1, Task 1.1/1.3)
- cnpg-operator (Phase 2, Task 2.1/2.3)
- cnpg-barman-plugin 은 Helm 아님 (upstream manifest.yaml) → single source 유지

## 주의 (메모리 project_argocd_multisource_deadlock)
- sources[] 배열 순서 고정. 변경 시 Git 단독 revert 로 복구 안 될 수 있음.
- Helm source 에 ref 지정 금지. Git source 에만 ref: values.
EOF

git add _workspace/cnpg-migration/12_kustomize-helm-decision.md
git commit -m "docs(cnpg): D-5 multi-source decision recorded (v0.4 review C1)"
```

## Task 1.1: `manifests/infra/cert-manager/` 디렉토리 구성 (D-5 multi-source)

> **리뷰 C1 반영**: helmCharts 블록 제거. Helm chart 는 ArgoCD Application `spec.sources[0]` 에서 렌더, Git 디렉토리는 values.yaml 제공 + Kustomize overlay 공간 용도.

**Files:**
- Create: `manifests/infra/cert-manager/namespace.yaml`
- Create: `manifests/infra/cert-manager/values.yaml`
- Create: `manifests/infra/cert-manager/kustomization.yaml`

**Step 1: namespace.yaml 작성** (Kustomize resources 에 최소 1개 리소스 필요 + `CreateNamespace=true` 중복 무해)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager
  labels:
    app.kubernetes.io/part-of: homelab
```

**Step 1.5: kustomization.yaml 작성** (Kustomize overlay — 향후 ClusterIssuer 등 홈랩 리소스 추가 공간)

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cert-manager
resources:
  - namespace.yaml
  # 향후 ClusterIssuer, Certificate 등 여기 추가
```

**Step 2: values.yaml 작성**

> **리뷰 C5 반영**: cert-manager chart v1.15.0+ 부터 `installCRDs` 는 **deprecated** (v1.16+ 일부 버전에서는 silently ignored). 신 키 `crds.enabled` + `crds.keep` 로 전환해야 Phase 1.4 검증에서 CRD 누락 디버깅 시간 절감. `crds.keep: true` 는 chart uninstall 시 CRD 잔존 — PV 유사 안전장치 (Phase 1 롤백 시 Certificate/Issuer 보존).

```yaml
# v1.15+ 신 키 (리뷰 C5). Phase 0 Task 0.2 Step 3 에서 `yq '.crds' 08_certmanager-chart-values.yaml` 로 실제 스키마 확인 후 확정.
crds:
  enabled: true
  keep: true          # helm uninstall 시 CRD 잔존 (이슈 #CR 보존)

resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { cpu: 200m, memory: 128Mi }

webhook:
  resources:
    requests: { cpu: 10m, memory: 32Mi }
    limits:   { cpu: 100m, memory: 64Mi }

cainjector:
  resources:
    requests: { cpu: 10m, memory: 32Mi }
    limits:   { cpu: 100m, memory: 64Mi }

prometheus:
  enabled: false
```

**Step 3: 로컬 빌드 검증** (Kustomize overlay 만, Helm chart 는 ArgoCD 가 렌더)

Run: `kubectl kustomize manifests/infra/cert-manager/ > /tmp/cert-manager-overlay.yaml && cat /tmp/cert-manager-overlay.yaml`
Expected: namespace.yaml 한 개 리소스만 렌더 (Helm chart 는 이 Task 범위 밖 — ArgoCD Application Sync 시 렌더됨).

**Step 4: 커밋**

Run:
```bash
git add manifests/infra/cert-manager/
git commit -m "feat(cert-manager): add values.yaml + namespace for multi-source Application"
```

## Task 1.2: ArgoCD infra AppProject whitelist 업데이트

**Files:**
- Modify: `argocd/projects/infra.yaml` (또는 실제 경로; `argocd/` 아래 AppProject 정의 찾아서)

**Step 1: 실제 AppProject 파일 위치 확인**

Run: `grep -rn "kind: AppProject" argocd/ 2>/dev/null | head -5`

**Step 2: clusterResourceWhitelist에 cert-manager 리소스 추가**

`_workspace/cnpg-migration/03_appproject-diff.md` 의 cert-manager 블록만 먼저 반영:
```yaml
- group: cert-manager.io
  kind: "*"
- group: acme.cert-manager.io
  kind: "*"
```

**Step 3: 로컬 validate**

Run: `kubectl apply --dry-run=client -f <appproject파일>`

**Step 4: 커밋**

Run:
```bash
git add argocd/<path>/infra.yaml
git commit -m "feat(argocd): whitelist cert-manager cluster resources"
```

## Task 1.3: ArgoCD Application 선언 (multi-source, D-5 (b))

**Files:**
- Create: `argocd/applications/infra/cert-manager.yaml`

**Step 1: Application YAML 작성** (traefik 패턴 재사용, 리뷰 C1 반영)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-3"
  labels:
    app.kubernetes.io/name: cert-manager
    app.kubernetes.io/component: cert-issuer
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: infra
  sources:
    # [0] Helm chart (Phase 0 I-2 에서 pin)
    - chart: cert-manager
      repoURL: https://charts.jetstack.io
      targetRevision: "<PIN_FROM_PHASE_0>"
      helm:
        valueFiles:
          - $values/manifests/infra/cert-manager/values.yaml
    # [1] Git overlay (values.yaml 제공 + namespace/미래 ClusterIssuer 리소스)
    - repoURL: https://github.com/ukkiee-dev/homelab.git
      targetRevision: main
      path: manifests/infra/cert-manager
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 3
      backoff: { duration: 5s, factor: 2, maxDuration: 3m }
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - SkipDryRunOnMissingResource=true
```

> **주의 (메모리 `project_argocd_multisource_deadlock`)**: `sources[]` 배열 순서/ref/targetRevision 변경은 반드시 Git PR 경유. source 추가·제거 시 ArgoCD Application 이 OOS 로 멈추면 kubectl patch 로 복구 필요할 수 있음.

**Step 2: validate**

Run: `kubectl apply --dry-run=client -f argocd/applications/infra/cert-manager.yaml`

**Step 3: 커밋 + push**

Run:
```bash
git add argocd/applications/infra/cert-manager.yaml
git commit -m "feat(argocd): add cert-manager application (sync-wave -3)"
git push origin main
```

## Task 1.4: ArgoCD sync 및 검증

**Step 1: Application sync 상태 모니터링**

Run:
```bash
argocd app sync cert-manager --prune
# 또는
kubectl -n argocd get app cert-manager -w
```
Expected: Synced · Healthy within 3 min.

**Step 2: Pod 상태 확인**

Run:
```bash
kubectl -n cert-manager get deploy
kubectl -n cert-manager get pods
```
Expected: 3 Deployment (controller/webhook/cainjector) Running.

**Step 3: CRD 등록 확인**

Run: `kubectl get crd | grep cert-manager`
Expected: certificates, issuers, clusterissuers, certificaterequests, orders, challenges.

**Step 4: Traefik ACME와 격리 확인 (회귀 점검)**

Run:
```bash
kubectl -n <traefik-ns> logs deploy/traefik | grep -i acme | tail -20
kubectl -n <traefik-ns> get secret -l acme
```
Expected: 기존 Traefik ACME 동작 영향 없음.

**Step 5: 완료 기록**

Run: `echo "Phase 1 완료: $(date -Iseconds)" >> _workspace/cnpg-migration/00_phase-log.md && git add _workspace/cnpg-migration/00_phase-log.md && git commit -m "chore(cnpg): phase 1 done"`

---

# Phase 2: CNPG operator + plugin 설치

## Task 2.1: `manifests/infra/cnpg-operator/` 구성 (D-5 multi-source)

> **리뷰 C1 반영**: helmCharts 블록 제거. traefik/cert-manager 패턴 적용.

**Files:**
- Create: `manifests/infra/cnpg-operator/namespace.yaml`
- Create: `manifests/infra/cnpg-operator/values.yaml`
- Create: `manifests/infra/cnpg-operator/kustomization.yaml`

**⚠️ 주의**: values.yaml 키 이름은 **Task 0.2 Step 3에서 덤프한 `_workspace/cnpg-migration/08_cnpg-chart-values.yaml`** 의 실제 스키마를 따를 것. 아래 예시는 개념 수준이며 chart 버전에 따라 다를 수 있음 (e.g. `monitoring.podMonitorEnabled` vs `monitoring.podMonitor.enabled` vs `podMonitor.create`).

**Step 1: namespace.yaml 작성**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cnpg-system
  labels:
    app.kubernetes.io/part-of: homelab
```

**Step 1.5: kustomization.yaml 작성**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cnpg-system
resources:
  - namespace.yaml
  # 리뷰 C3 대응 시 metrics-service.yaml 여기 추가 예정 (Task 5.1.1)
```

**Step 2: values.yaml 작성 (08_cnpg-chart-values.yaml 스키마 기반)**

덤프한 chart values에서 필요한 키만 override:

```yaml
# ⚠️ 아래 키들은 예시. 실제 Task 0.2 덤프와 일치하는 키로 작성할 것.
resources:
  requests: { cpu: 100m, memory: 200Mi }
  limits:   { cpu: 500m, memory: 400Mi }

monitoring:
  # PodMonitor 관련 키 (chart 버전에 따라 이름 상이): Alloy 직접 scrape 이므로 비활성화
  podMonitorEnabled: false
  grafanaDashboard:
    create: false

logLevel: info

# CRD 설치 (chart 버전에 따라 키 이름 상이)
crds:
  create: true
```

**Step 2.5: values.yaml 렌더링 사전 검증 (podMonitor 비활성화 + Service 생성 유무 — 리뷰 C3)**

Helm 만으로 템플릿을 미리 렌더해 Service/PodMonitor 생성 여부를 **로컬에서 선점 확인**:

```bash
# Helm template 으로 chart 만 렌더 (ArgoCD 시뮬레이션)
CNPG_VER="<Phase 0 에서 확정>"
helm template cnpg cnpg/cloudnative-pg --version "$CNPG_VER" \
  --values manifests/infra/cnpg-operator/values.yaml \
  --namespace cnpg-system \
  > /tmp/cnpg-helm-rendered.yaml

# PodMonitor 미생성 확인
grep -c "^kind: PodMonitor" /tmp/cnpg-helm-rendered.yaml
# Expected: 0

# 리뷰 C3: operator 메트릭 Service 자동 생성 여부 확인
grep -E "^kind: Service$" -A 5 /tmp/cnpg-helm-rendered.yaml | head -40
# metrics Service 가 안 보이면 Task 5.1.1 로 수동 Service 추가 필요.
```

0이 아니면 values.yaml 의 키 이름이 chart 스키마와 어긋난 것 → `08_cnpg-chart-values.yaml` 재확인 후 수정.

**Step 3: Kustomize overlay 로컬 빌드 검증**

Run: `kubectl kustomize manifests/infra/cnpg-operator/ > /tmp/cnpg-overlay.yaml && cat /tmp/cnpg-overlay.yaml`
Expected: namespace.yaml 만 렌더 (Helm chart 는 이 Task 범위 밖).

**Step 4: 커밋**

Run:
```bash
git add manifests/infra/cnpg-operator/
git commit -m "feat(cnpg): add values.yaml + namespace for multi-source Application"
```

## Task 2.2: AppProject whitelist 업데이트 (CNPG)

**Files:**
- Modify: `argocd/<path>/infra.yaml`

**Step 1: CNPG 리소스 추가**

```yaml
- group: postgresql.cnpg.io
  kind: "*"
```

admission webhook이 이미 cert-manager 시 추가되지 않았으면 추가:
```yaml
- group: admissionregistration.k8s.io
  kind: ValidatingWebhookConfiguration
- group: admissionregistration.k8s.io
  kind: MutatingWebhookConfiguration
```

**Step 2: 커밋**

Run:
```bash
git add argocd/<path>/infra.yaml
git commit -m "feat(argocd): whitelist CNPG cluster resources"
```

## Task 2.3: CNPG operator Application 선언 (multi-source, D-5 (b))

**Files:**
- Create: `argocd/applications/infra/cnpg-operator.yaml`

**Step 1: Application YAML** (traefik/cert-manager 패턴 재사용 · 리뷰 C1 반영)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cnpg-operator
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
  labels:
    app.kubernetes.io/name: cnpg-operator
    app.kubernetes.io/component: database-operator
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: infra
  sources:
    # [0] Helm chart
    - chart: cloudnative-pg
      repoURL: https://cloudnative-pg.github.io/charts
      targetRevision: "<PIN_FROM_PHASE_0>"
      helm:
        valueFiles:
          - $values/manifests/infra/cnpg-operator/values.yaml
    # [1] Git overlay (values.yaml + namespace + 향후 metrics-service kustomize patch)
    - repoURL: https://github.com/ukkiee-dev/homelab.git
      targetRevision: main
      path: manifests/infra/cnpg-operator
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: cnpg-system
  # 리뷰 P7 + 메모리 project_traefik_helm_v39_gomemlimit_ssa 정신:
  # CNPG operator 가 Cluster CR 등에 default 값 자동 채움 (e.g. encoding) 으로 drift 유발 가능성.
  # Phase 9 관찰에서 drift 발생 시 구체적 경로를 여기 추가 (Cluster CR, managed.roles.password 회전 등).
  # 초기엔 비워두되 Phase 3-6 에서 관찰된 drift 기록.
  # ignoreDifferences:
  #   - group: postgresql.cnpg.io
  #     kind: Cluster
  #     jqPathExpressions:
  #       - '.spec.postgresql.parameters.archive_command'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 3
      backoff: { duration: 5s, factor: 2, maxDuration: 3m }
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - SkipDryRunOnMissingResource=true
```

**Step 2: 커밋 + push**

Run:
```bash
git add argocd/applications/infra/cnpg-operator.yaml
git commit -m "feat(argocd): add CNPG operator application (sync-wave -2)"
git push origin main
```

## Task 2.4: Operator sync 및 검증

**Step 1: sync 모니터링**

Run: `argocd app sync cnpg-operator --prune`
Expected: Synced · Healthy within 3 min.

**Step 2: Pod + CRD 확인**

Run:
```bash
kubectl -n cnpg-system get deploy,pod
kubectl get crd | grep cnpg.io
```
Expected:
- Deployment `cnpg-controller-manager` Running
- CRD 8종: clusters, backups, scheduledbackups, poolers, publications, subscriptions, databases, clusterimagecatalogs

**Step 3: 웹훅 health**

Run:
```bash
kubectl get validatingwebhookconfiguration | grep cnpg
kubectl get mutatingwebhookconfiguration | grep cnpg
```
Expected: 각 1개 이상 등록.

**Step 4: 로그 점검**

Run: `kubectl -n cnpg-system logs deploy/cnpg-controller-manager --tail=50`
Expected: "Starting manager" 성공, error 없음.

## Task 2.5: `manifests/infra/cnpg-barman-plugin/` 구성

**Files:**
- Create: `manifests/infra/cnpg-barman-plugin/kustomization.yaml`

**Step 1: plugin manifest URL 확인**

Run:
```bash
# 최신 릴리스 manifest URL (Phase 0 I-2에서 pin 한 버전 기준)
PLUGIN_VER="<PIN>"
echo "https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/${PLUGIN_VER}/manifest.yaml"
```

**Step 2: kustomization.yaml (원격 리소스 참조)**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cnpg-system
resources:
  - https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/<PIN>/manifest.yaml
```

> Alternative: manifest를 로컬로 다운로드해서 `manifest.yaml` 파일로 저장 (재현성 ↑). Renovate로 버전 추적 가능.

**Step 3: 로컬 빌드 검증**

Run: `kubectl kustomize manifests/infra/cnpg-barman-plugin/ | head -60`
Expected: ObjectStore CRD, Deployment `barman-cloud`, Service, RBAC 포함.

**Step 4: 커밋**

Run:
```bash
git add manifests/infra/cnpg-barman-plugin/
git commit -m "feat(cnpg): add barman-cloud plugin kustomization"
```

## Task 2.6: AppProject whitelist 업데이트 (plugin)

**Files:**
- Modify: `argocd/<path>/infra.yaml`

**Step 1: plugin 리소스 추가**

```yaml
- group: barmancloud.cnpg.io
  kind: "*"
```

**Step 2: 커밋**

Run:
```bash
git add argocd/<path>/infra.yaml
git commit -m "feat(argocd): whitelist plugin-barman-cloud resources"
```

## Task 2.7: Plugin Application 선언

**Files:**
- Create: `argocd/applications/infra/cnpg-barman-plugin.yaml`

**Step 1: Application YAML**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cnpg-barman-plugin
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: infra
  source:
    repoURL: https://github.com/ukkiee-dev/homelab
    targetRevision: HEAD
    path: manifests/infra/cnpg-barman-plugin
  destination:
    server: https://kubernetes.default.svc
    namespace: cnpg-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - Replace=true
      - SkipDryRunOnMissingResource=true
```

**Step 2: 커밋 + push**

Run:
```bash
git add argocd/applications/infra/cnpg-barman-plugin.yaml
git commit -m "feat(argocd): add barman-cloud plugin application (sync-wave -1)"
git push origin main
```

## Task 2.8: Plugin 검증 (cert-manager 의존)

**Step 1: sync 상태**

Run: `argocd app sync cnpg-barman-plugin --prune`

**Step 2: Plugin pod + cert 발급 확인**

Run:
```bash
kubectl -n cnpg-system get pod -l app.kubernetes.io/name=barman-cloud
kubectl -n cnpg-system get certificate
kubectl -n cnpg-system get certificaterequest
```
Expected:
- `barman-cloud` Deployment Running
- Certificate READY=True (cert-manager가 발급 완료)

**Step 3: gRPC Service 확인**

Run: `kubectl -n cnpg-system get svc | grep barman`
Expected: `barman-cloud` Service 존재.

**Step 4: ObjectStore CRD 등록 확인**

Run: `kubectl get crd objectstores.barmancloud.cnpg.io`
Expected: 존재.

**Step 5: Phase 2 완료 기록**

Run:
```bash
echo "Phase 2 완료: $(date -Iseconds)" >> _workspace/cnpg-migration/00_phase-log.md
git add _workspace/cnpg-migration/00_phase-log.md
git commit -m "chore(cnpg): phase 2 done"
git push origin main
```

---

# Phase 3: 첫 Cluster PoC (`pg-trial`)

> PoC 목적: Cluster + managed.roles + Database CRD 체인이 실제 동작하는지 확인. 백업은 Phase 4에서.

## Task 3.1: `pg-trial` namespace 생성

**Files:**
- Create: `manifests/apps/pg-trial/namespace.yaml`

**Step 1: namespace 파일**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: pg-trial
  labels:
    app.kubernetes.io/part-of: pg-trial
```

**Step 2: 수동 적용 (트라이얼은 ArgoCD 통하지 않음)**

Run:
```bash
kubectl apply -f manifests/apps/pg-trial/namespace.yaml
kubectl get ns pg-trial
```

## Task 3.2: Role password SealedSecret 생성

**Files:**
- Create: `manifests/apps/pg-trial/role-secrets.sealed.yaml`

**Step 1: 평문 secret 생성 + kubeseal**

Run:
```bash
PASSWORD=$(openssl rand -base64 24)
cat > /tmp/trial-role.yaml <<EOF
apiVersion: v1
kind: Secret
type: kubernetes.io/basic-auth
metadata:
  name: pg-trial-pg-demo-credentials
  namespace: pg-trial
  labels:
    cnpg.io/reload: "true"
stringData:
  username: demo
  password: ${PASSWORD}
EOF

kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets-controller \
  --format=yaml \
  < /tmp/trial-role.yaml \
  > manifests/apps/pg-trial/role-secrets.sealed.yaml

rm /tmp/trial-role.yaml
```

**Step 2: 적용 및 unseal 확인**

Run:
```bash
kubectl apply -f manifests/apps/pg-trial/role-secrets.sealed.yaml
# sealed-secrets controller가 unseal할 때까지 10초 대기
sleep 10
kubectl -n pg-trial get secret pg-trial-pg-demo-credentials
```
Expected: Secret 존재, type `kubernetes.io/basic-auth`.

## Task 3.3: Cluster CR 선언 (managed.roles 포함, 백업 제외)

**Files:**
- Create: `manifests/apps/pg-trial/cluster.yaml`

**Step 1: Cluster YAML**

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-trial-pg
  namespace: pg-trial
  labels:
    app.kubernetes.io/name: pg-trial-pg
    app.kubernetes.io/component: database
    app.kubernetes.io/part-of: pg-trial
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:<PIN_FROM_PHASE_0>
  primaryUpdateStrategy: unsupervised  # single-instance minor upgrade 무인 재시작
  storage:
    size: 5Gi     # D 시나리오 확정 (local-path resize 미지원) → 넉넉한 default. app 별 override via .app-config.yml
    storageClass: local-path
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: 500m, memory: 512Mi }
  monitoring:
    enablePodMonitor: false
  managed:
    roles:
      - name: demo
        ensure: present
        login: true
        passwordSecret:
          name: pg-trial-pg-demo-credentials
```

**Step 2: 적용**

Run: `kubectl apply -f manifests/apps/pg-trial/cluster.yaml`

**Step 3: Cluster reconcile 대기**

Run: `kubectl -n pg-trial get cluster pg-trial-pg -w`
Wait until `STATUS=Cluster in healthy state` (2–3분).

**Step 4: Pod + PVC 확인**

Run:
```bash
kubectl -n pg-trial get pod,pvc
kubectl -n pg-trial get cluster pg-trial-pg -o jsonpath='{.status.readyInstances}'
```
Expected: 1 pod Running, 1 PVC Bound, readyInstances=1.

## Task 3.4: managed.roles 실제 생성 검증

**Step 1: primary pod 동적 탐색 헬퍼**

CNPG는 `cnpg.io/cluster` · `cnpg.io/instanceRole=primary` label을 제공하므로 pod 이름 하드코딩 금지 (failover/재생성 대비):

```bash
# 이후 Task들도 이 패턴 재사용
get_primary_pod() {
  local ns=$1
  local cluster=$2
  kubectl -n "$ns" get pod \
    -l "cnpg.io/cluster=${cluster},cnpg.io/instanceRole=primary" \
    -o jsonpath='{.items[0].metadata.name}'
}
PRIMARY=$(get_primary_pod pg-trial pg-trial-pg)
echo "primary pod: $PRIMARY"
```

**Step 2: psql로 role 존재 확인**

Run:
```bash
kubectl -n pg-trial exec -it "$PRIMARY" -- psql -U postgres -c "\du"
```
Expected: `demo` role 출력, attribute `login`.

**Step 3: 비밀번호 연결 검증**

Run:
```bash
PASS=$(kubectl -n pg-trial get secret pg-trial-pg-demo-credentials -o jsonpath='{.data.password}' | base64 -d)
kubectl -n pg-trial exec -it "$PRIMARY" -- \
  psql "postgresql://demo:${PASS}@localhost:5432/postgres" -c "SELECT current_user;"
```
Expected: `current_user = demo`.

## Task 3.5: Database CRD 적용

**Files:**
- Create: `manifests/apps/pg-trial/database.yaml`

**Step 1: Database YAML**

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: demo
  namespace: pg-trial
spec:
  cluster:
    name: pg-trial-pg
  name: demo
  owner: demo
```

**Step 2: 적용**

Run:
```bash
kubectl apply -f manifests/apps/pg-trial/database.yaml
kubectl -n pg-trial get database demo -w
```
Wait until `APPLIED=True` (30–60s).

**Step 3: DB 존재 + owner 검증**

Run:
```bash
PRIMARY=$(kubectl -n pg-trial get pod -l cnpg.io/cluster=pg-trial-pg,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
kubectl -n pg-trial exec -it "$PRIMARY" -- psql -U postgres -c "\l demo"
```
Expected: demo DB 목록에 `owner=demo`.

## Task 3.6: App 연결 시뮬레이션

**Step 1: 임시 psql Pod로 앱 연결 패턴 시뮬레이션**

Run:
```bash
kubectl -n pg-trial run psql-client --rm -it --restart=Never \
  --image=postgres:16-alpine \
  --env="PGPASSWORD=$(kubectl -n pg-trial get secret pg-trial-pg-demo-credentials -o jsonpath='{.data.password}' | base64 -d)" \
  --command -- \
  psql "postgresql://demo@pg-trial-pg-rw:5432/demo?sslmode=require" -c "CREATE TABLE t(id serial primary key, v text); INSERT INTO t(v) VALUES('hello') RETURNING *;"
```
Expected: table 생성 + `hello` row 반환.

## Task 3.7: Teardown 검증

**Step 1: namespace 삭제**

Run:
```bash
kubectl delete ns pg-trial
# 약 1-2분 대기
kubectl get cluster --all-namespaces
kubectl get pvc --all-namespaces | grep pg-trial  # 출력 없어야 함
kubectl get secret --all-namespaces | grep pg-trial  # 출력 없어야 함
```
Expected: 모든 리소스 삭제 완료.

**Step 2: 재현성 확인: 매니페스트 다시 apply → 동일 상태 재현**

Run:
```bash
kubectl apply -f manifests/apps/pg-trial/namespace.yaml
kubectl apply -f manifests/apps/pg-trial/role-secrets.sealed.yaml
kubectl apply -f manifests/apps/pg-trial/cluster.yaml
kubectl apply -f manifests/apps/pg-trial/database.yaml
# 대기 후 재확인 (3.3-3.5 검증 반복)
```

**Step 3: PoC commit (향후 참조용)**

Run:
```bash
git add manifests/apps/pg-trial/
git commit -m "chore(cnpg): pg-trial PoC manifests (keep for future reference)"
git push origin main
```

> 주의: `pg-trial` 은 ArgoCD 관리 대상 아님. 직접 수동 apply 스타일. 나중에 Phase 6에서 실제 프로젝트는 ArgoCD Application으로 등록.

## Task 3.8: CNPG 메트릭 dump → Appendix C 박제 (I-1 이관)

> 설계 doc 원본은 "Phase 0 I-1" 에서 dump 하겠다고 했으나 Phase 0 시점엔 Cluster 자체가 없어서 `/metrics` 접근 불가. **Phase 3 PoC 완료 시점으로 이관.** Phase 5 알람 규칙의 실존 메트릭 검증 근거로 사용.

**Step 1: Primary pod /metrics 덤프**

```bash
PRIMARY=$(kubectl -n pg-trial get pod -l cnpg.io/cluster=pg-trial-pg,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
kubectl -n pg-trial exec -it "$PRIMARY" -- curl -s http://localhost:9187/metrics \
  | grep -E '^cnpg_' | awk '{print $1}' | sort -u \
  > _workspace/cnpg-migration/10_cnpg-metrics.txt

wc -l _workspace/cnpg-migration/10_cnpg-metrics.txt
head -30 _workspace/cnpg-migration/10_cnpg-metrics.txt
```
Expected: 20개 이상 메트릭 이름. `cnpg_collector_*`, `cnpg_pg_*` prefix 다수.

**Step 2: Phase 5 알람에 사용할 메트릭 실존 재확인 (C2 원칙)**

```bash
for m in cnpg_collector_up \
         cnpg_collector_last_available_backup_timestamp \
         cnpg_collector_pg_wal_archive_status; do
  if grep -qx "$m" _workspace/cnpg-migration/10_cnpg-metrics.txt; then
    echo "✅ $m"
  else
    echo "⚠️  $m 실존 안 함 → Phase 5.4 알람 규칙 재작성 필요"
  fi
done
```
Expected: 3개 모두 ✅. 실패 시 chart/operator 버전에 따라 메트릭 이름 변경되었을 가능성 → Phase 5.4 expr 수정.

**Step 3: 디자인 doc Appendix C.1 에 실제 dump 붙여넣기**

Modify: `docs/plans/2026-04-20-cloudnativepg-migration-design.md` §Appendix C.1

`<TBD: ...>` 블록을 `10_cnpg-metrics.txt` 내용으로 교체 (상위 30줄 + "전체 파일 참조" 경로).

**Step 4: 커밋**

```bash
git add _workspace/cnpg-migration/10_cnpg-metrics.txt docs/plans/2026-04-20-cloudnativepg-migration-design.md
git commit -m "docs(cnpg): record actual exporter metrics in design appendix C (from phase 3 PoC)"
```

## Task 3.9: Phase 3 완료 기록

Run:
```bash
echo "Phase 3 완료: $(date -Iseconds), PoC + 메트릭 dump" >> _workspace/cnpg-migration/00_phase-log.md
git add _workspace/cnpg-migration/00_phase-log.md
git commit -m "chore(cnpg): phase 3 PoC done"
```

---

# Phase 4: 백업 통합 + PITR 드라이런

## Task 4.1: R2 credential SealedSecret 생성

**Files:**
- Create: `manifests/apps/pg-trial/r2-backup.sealed.yaml`

**Step 1: 평문 secret → kubeseal**

Run:
```bash
source _workspace/cnpg-migration/02_r2-credentials.txt  # ACCESS_KEY_ID, SECRET_ACCESS_KEY
cat > /tmp/r2-backup.yaml <<EOF
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: r2-pg-backup
  namespace: pg-trial
stringData:
  ACCESS_KEY_ID: "${R2_ACCESS_KEY_ID}"
  SECRET_ACCESS_KEY: "${R2_SECRET_ACCESS_KEY}"
EOF

kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets-controller \
  --format=yaml \
  < /tmp/r2-backup.yaml \
  > manifests/apps/pg-trial/r2-backup.sealed.yaml

rm /tmp/r2-backup.yaml
```

**Step 2: 적용 + unseal 확인**

Run:
```bash
kubectl apply -f manifests/apps/pg-trial/r2-backup.sealed.yaml
sleep 10
kubectl -n pg-trial get secret r2-pg-backup -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d | cut -c1-5
```
Expected: access key prefix 5자 출력.

## Task 4.2: ObjectStore CR 생성

**Files:**
- Create: `manifests/apps/pg-trial/objectstore.yaml`

**Step 1: ObjectStore YAML**

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: pg-trial-backup
  namespace: pg-trial
spec:
  configuration:
    destinationPath: s3://homelab-db-backups/pg-trial
    endpointURL: https://<ACCOUNT_ID>.r2.cloudflarestorage.com
    s3Credentials:
      accessKeyId:
        name: r2-pg-backup
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: r2-pg-backup
        key: SECRET_ACCESS_KEY
    wal:
      compression: gzip
    data:
      compression: gzip
  retentionPolicy: "14d"
```

**Step 2: 적용**

Run:
```bash
kubectl apply -f manifests/apps/pg-trial/objectstore.yaml
kubectl -n pg-trial get objectstore
```
Expected: READY=True.

## Task 4.3: Cluster.spec.plugins 추가

**Files:**
- Modify: `manifests/apps/pg-trial/cluster.yaml` (plugins 블록 추가)

**Step 1: plugins 블록 추가**

```yaml
spec:
  # ... 기존 설정 ...
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: pg-trial-backup
        serverName: pg-trial-pg
```

**Step 2: 적용 + WAL archive 시작 확인**

Run:
```bash
kubectl apply -f manifests/apps/pg-trial/cluster.yaml
# 1분 대기
PRIMARY=$(kubectl -n pg-trial get pod -l cnpg.io/cluster=pg-trial-pg,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
kubectl -n pg-trial logs "$PRIMARY" -c postgres | grep -i "archive" | tail -10
```
Expected: WAL archive 관련 로그 출력 (plugin 호출 흔적).

## Task 4.4: on-demand Backup 수동 트리거

**Files:**
- Create: `manifests/apps/pg-trial/manual-backup.yaml`

**Step 1: Backup CR**

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: pg-trial-manual-001
  namespace: pg-trial
spec:
  cluster:
    name: pg-trial-pg
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

**Step 2: 적용 + 완료 대기**

Run:
```bash
kubectl apply -f manifests/apps/pg-trial/manual-backup.yaml
kubectl -n pg-trial get backup pg-trial-manual-001 -w
```
Wait until `STATUS=completed` (2–5분).

**Step 3: R2 버킷에서 base backup 파일 확인**

Run:
```bash
source _workspace/cnpg-migration/02_r2-credentials.txt
aws --endpoint-url="$R2_ENDPOINT" --region auto \
  s3 ls "s3://homelab-db-backups/pg-trial/pg-trial-pg/base/" --recursive | head -20
```
Expected: `base.tar.gz` 또는 유사 파일 다수.

**Step 4: WAL 파일도 확인**

Run:
```bash
aws --endpoint-url="$R2_ENDPOINT" --region auto \
  s3 ls "s3://homelab-db-backups/pg-trial/pg-trial-pg/wals/" | head -10
```
Expected: WAL 세그먼트 파일 존재.

## Task 4.4.5: R2 Bucket Lock × Barman backup-delete 호환성 POC (v0.4 리뷰 H3 신규)

> **리뷰 H3 반영**: design §8.4 에서 명시한 "Bucket Lock + barman backup-delete 호환성 E2E POC". Lock 활성 상태에서 Barman 이 retentionPolicy 에 따른 객체 삭제를 시도할 때, Lock rule (prefix=wal, Age=21d) 과 충돌하는지 검증.

**Step 1: 현재 상태 사전 박제**

```bash
# 버킷 객체 리스트
source _workspace/cnpg-migration/02_r2-credentials.txt
aws --endpoint-url="$R2_ENDPOINT" --region auto \
  s3 ls "s3://homelab-db-backups/pg-trial/" --recursive > /tmp/pre-pocc.txt
wc -l /tmp/pre-pocc.txt
```

**Step 2: retentionPolicy 짧게 일시 변경 (POC 전용)**

POC 를 위해 ObjectStore 의 retentionPolicy 를 `14d` → `1h` 로 일시 하향:
```bash
kubectl -n pg-trial patch objectstore pg-trial-backup --type merge \
  --patch '{"spec":{"retentionPolicy":"1h"}}'
```

**Step 3: Backup 여러 번 생성 후 1시간+ 대기**

```bash
for i in 1 2 3; do
  kubectl -n pg-trial apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: pg-trial-pocc-$i
  namespace: pg-trial
spec:
  cluster: { name: pg-trial-pg }
  method: plugin
  pluginConfiguration: { name: barman-cloud.cloudnative-pg.io }
EOF
  kubectl -n pg-trial wait --for=jsonpath='{.status.phase}'=completed \
    backup/pg-trial-pocc-$i --timeout=5m
  sleep 120
done

# WAL 도 Lock 범위 (wal/ prefix) 에서 생성되도록 60분 대기
sleep 3600
```

**Step 4: Barman 이 backup-delete 시도 — 결과 관찰**

Plugin 로그에서 retentionPolicy 적용 흔적 + Lock 거부 에러 유무:
```bash
PLUGIN_POD=$(kubectl -n cnpg-system get pod -l app.kubernetes.io/name=barman-cloud -o jsonpath='{.items[0].metadata.name}')
kubectl -n cnpg-system logs "$PLUGIN_POD" --tail=200 | grep -iE "delete|lock|retention|error"
```

판정 기준:
- **호환**: wal/ prefix 의 객체는 Lock 21d 로 보호되어 남고, base/ prefix 의 오래된 객체는 정상 삭제됨. Plugin 에러 로그 없음.
- **부분 충돌**: Plugin 이 삭제 시도 → Lock 거부 → 재시도 무한 loop. 로그에 `AccessDenied` 반복. 조치: R2 Bucket Lock 의 prefix 를 `wal/` 로만 국한했는지 재확인, `base/` 에는 적용 안 되도록.
- **전면 충돌**: Plugin 이 모든 삭제에 실패, R2 공간 무한 증가. 조치: 본 POC fallback 결정 박제 — Bucket Lock 비활성 + R2 lifecycle 만 사용, §16 외장 SSD mirror 우선순위 상향.

**Step 5: retentionPolicy 복원 + POC 리소스 정리**

```bash
kubectl -n pg-trial patch objectstore pg-trial-backup --type merge \
  --patch '{"spec":{"retentionPolicy":"14d"}}'
kubectl -n pg-trial delete backup pg-trial-pocc-1 pg-trial-pocc-2 pg-trial-pocc-3
```

**Step 6: 결과 박제**

`_workspace/cnpg-migration/14_r2-object-lock.md` 에 POC 결과 (호환/부분충돌/전면충돌) + 조치 결정 기록. 전면 충돌 시 Task 0.5 Step 5 의 `cloudflare_r2_bucket_lock` 리소스 제거 PR 생성 + design §16 외장 SSD mirror priority 상향 반영.

## Task 4.5: ScheduledBackup 추가

**Files:**
- Create: `manifests/apps/pg-trial/scheduled-backup.yaml`

**Step 1: ScheduledBackup YAML**

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: pg-trial-pg-daily
  namespace: pg-trial
spec:
  schedule: "0 0 18 * * *"       # UTC 18:00 = KST 03:00
  cluster:
    name: pg-trial-pg
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  backupOwnerReference: cluster      # v0.4 H5 + 리뷰 C4: audit trail 보존, ScheduledBackup spec 변경 시 Backup CR 이력 유지
```

**Step 2: 적용**

Run: `kubectl apply -f manifests/apps/pg-trial/scheduled-backup.yaml`

**Step 3: 다음 실행 시각 확인**

Run:
```bash
kubectl -n pg-trial get scheduledbackup pg-trial-pg-daily -o jsonpath='{.status.nextScheduleTime}'
```
Expected: 다음 UTC 18:00 timestamp.

## Task 4.6: PITR 드라이런 (두 시나리오, v0.4 리뷰 C2 반영)

> **리뷰 C2 반영**: 단일 "별도 namespace 복구" 시나리오는 design §8.2 의 "동일 namespace 재선언" 절차를 **검증하지 못한다**. Runbook 정확도를 위해 두 시나리오로 분리.
>
> - **Task 4.6a — 동일-namespace 시점복구**: design §8.2 의 5단계 PR 흐름(selfHeal off → cluster delete → bootstrap.recovery PR → roles reapply → selfHeal on) 검증. 평시 PITR Runbook 의 기반.
> - **Task 4.6b — 별도-namespace 복구**: disaster scenario (원본 cluster 복구 불능, DR replica 필요) 검증. 별도 Runbook 의 기반.
>
> Task 4.7 Runbook 작성은 4.6a 기반. 4.6b 는 `docs/runbooks/postgresql/cnpg-dr-new-namespace.md` (Phase 9) 의 근거.

### Task 4.6a — 동일-namespace 시점복구 (design §8.2 절차 검증)

> Phase 3 PoC 의 pg-trial 은 ArgoCD 관리 밖 (수동 apply) 이므로 §8.2 의 "PR ①/②/③" 단계는 kubectl 직접 조작으로 시뮬레이션. Phase 6 이후 실제 프로젝트의 PITR 은 반드시 Git PR 경유.

**Files:**
- Modify: `manifests/apps/pg-trial/cluster.yaml` (bootstrap.recovery 블록 추가 → 복구 후 제거)

**Step 1: 파괴적 작업 이전 시점 기록 + 데이터 파괴**

Run:
```bash
PRIMARY=$(kubectl -n pg-trial get pod -l cnpg.io/cluster=pg-trial-pg,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')

# 사전 마커 INSERT
kubectl -n pg-trial exec -it "$PRIMARY" -- \
  psql -U postgres -d demo -c "INSERT INTO t(v) VALUES('pre-restore-marker-$(date -Iseconds)') RETURNING *;"
TARGET_TIME=$(date -u +"%Y-%m-%d %H:%M:%S+00")
echo "TARGET_TIME=$TARGET_TIME" > /tmp/restore-target.txt
echo "복구 목표 시각: $TARGET_TIME"

# WAL archive 커밋되도록 60초 이상 대기
sleep 90

# 파괴적 작업 시뮬레이션
kubectl -n pg-trial exec -it "$PRIMARY" -- \
  psql -U postgres -d demo -c "DELETE FROM t; INSERT INTO t(v) VALUES('post-destruction');"
```

**Step 2: PV reclaim policy 사전 확인** (design §8.2 Step 0)

Run:
```bash
PV_NAME=$(kubectl -n pg-trial get pvc -l cnpg.io/cluster=pg-trial-pg -o jsonpath='{.items[0].spec.volumeName}')
kubectl get pv "$PV_NAME" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'
# Expected: Delete (local-path 기본). Retain 이면 Step 3 전에 수동 kubectl delete pv 필요.
```

**Step 3: 원본 Cluster 삭제** (design §8.2 Step 2)

Run:
```bash
kubectl -n pg-trial delete cluster pg-trial-pg
# finalizer cascade 대기
kubectl -n pg-trial wait --for=delete cluster/pg-trial-pg --timeout=5m

# PVC 는 자동 삭제되지 않을 수 있음 — 명시적 정리
kubectl -n pg-trial delete pvc -l cnpg.io/cluster=pg-trial-pg

# PV 자동 삭제 확인 (local-path Delete 정책)
sleep 15
kubectl get pv | grep pg-trial || echo "PV 정리 완료"
```

> webhook 데드락 발생 시 design §9 M3 escape (`kubectl -n cnpg-system scale deploy/cnpg-controller-manager --replicas=0`) 사용 후 재시작.

**Step 4: 동일 namespace 에 recovery Cluster 재선언** (design §8.2 Step 3)

`manifests/apps/pg-trial/cluster.yaml` 를 수정 — `spec.bootstrap.recovery` + `spec.externalClusters[]` 블록 추가 (기존 `initdb` 또는 초기 bootstrap 블록 일시 대체):

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-trial-pg    # 동일 이름 재사용
  namespace: pg-trial  # 동일 namespace
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:<PIN>
  storage: { size: 5Gi, storageClass: local-path }
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: 500m, memory: 512Mi }
  bootstrap:
    recovery:
      source: pg-trial-backup-source
      recoveryTarget:
        targetTime: "<TARGET_TIME 값 치환>"
  externalClusters:
    - name: pg-trial-backup-source
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: pg-trial-backup
          serverName: pg-trial-pg
  managed:
    roles:
      - name: demo
        ensure: present
        login: true
        passwordSecret: { name: pg-trial-pg-demo-credentials }
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: pg-trial-backup
        serverName: pg-trial-pg
```

Apply:
```bash
kubectl apply -f manifests/apps/pg-trial/cluster.yaml
kubectl -n pg-trial get cluster pg-trial-pg -w
```
Wait until ready (5–10분, base 복원 + WAL replay).

**Step 5: 복구 데이터 검증**

Run:
```bash
PRIMARY=$(kubectl -n pg-trial get pod -l cnpg.io/cluster=pg-trial-pg,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
kubectl -n pg-trial exec -it "$PRIMARY" -- \
  psql -U postgres -d demo -c "SELECT * FROM t ORDER BY id;"
```
Expected: `pre-restore-marker` row 존재, `post-destruction` 행 **없음**. role `demo` 자동 재생성 확인.

**Step 6: bootstrap.recovery 제거 + 평상시 상태 복원** (design §8.2 Step 5)

`manifests/apps/pg-trial/cluster.yaml` 에서 `spec.bootstrap.recovery` + `spec.externalClusters[]` 블록 삭제, 원본 spec 복원 후 apply:
```bash
kubectl apply -f manifests/apps/pg-trial/cluster.yaml
# recovery 블록 제거 후에도 cluster 는 그대로 유지 (이미 bootstrap 완료 상태)
kubectl -n pg-trial get cluster pg-trial-pg
```

Expected: Cluster healthy 유지, 새 데이터 작성 가능.

**Step 7: 소요 시간 측정 + 박제**

Run:
```bash
echo "Task 4.6a 동일-namespace PITR: $(date -Iseconds) · TARGET=${TARGET_TIME} · base+WAL replay 소요 <min>분" \
  >> _workspace/cnpg-migration/05_pitr-drills.md
```
이 값이 Task 4.7 Runbook 및 §8 RTO/RPO 수치의 근거.

### Task 4.6b — 별도-namespace 복구 (disaster scenario, DR replica)

> 시나리오: 원본 cluster 가 살아 있지만 DR 검증용 별도 namespace 에 recovery cluster 를 띄워 데이터 확인 (예: 감사·compliance 용 시점별 snapshot 조사). 원본 cluster 는 건드리지 않는다.

**Files:**
- Create: `manifests/apps/pg-trial-restore/cluster-recovery.yaml`

**Step 1: 복구용 namespace 생성 + R2 SealedSecret 재seal**

R2 credential은 namespace-scoped이므로 `pg-trial-restore` 용으로 신규 seal.

Run:
```bash
# 1) namespace 생성
kubectl create ns pg-trial-restore

# 2) credential 평문 로드 (Task 0.5 에서 저장한 파일)
source _workspace/cnpg-migration/02_r2-credentials.txt

# 3) 평문 Secret 작성 (tmp)
cat > /tmp/r2-backup-restore.yaml <<EOF
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: r2-pg-backup
  namespace: pg-trial-restore
stringData:
  ACCESS_KEY_ID: "${R2_ACCESS_KEY_ID}"
  SECRET_ACCESS_KEY: "${R2_SECRET_ACCESS_KEY}"
EOF

# 4) namespace-scoped seal
kubeseal --controller-namespace sealed-secrets \
         --controller-name sealed-secrets-controller \
         --format=yaml \
         < /tmp/r2-backup-restore.yaml \
         > /tmp/r2-backup-restore.sealed.yaml

rm /tmp/r2-backup-restore.yaml

# 5) apply + unseal 확인
kubectl apply -f /tmp/r2-backup-restore.sealed.yaml
sleep 10
kubectl -n pg-trial-restore get secret r2-pg-backup -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d | cut -c1-5
```
Expected: access key prefix 5자 출력 → seal/unseal 성공.

**Step 2: 별도 namespace 복구 Cluster YAML**

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-trial-pg     # 원본과 동일 이름 가능 (namespace 분리)
  namespace: pg-trial-restore
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:<PIN>
  storage: { size: 1Gi }
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: 500m, memory: 512Mi }
  bootstrap:
    recovery:
      source: pg-trial-backup-source
      recoveryTarget:
        targetTime: "<TARGET_TIME>"
  externalClusters:
    - name: pg-trial-backup-source
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: pg-trial-backup
          serverName: pg-trial-pg
```

**Step 3: 적용 + 복구 완료 대기**

Run:
```bash
kubectl apply -f manifests/apps/pg-trial-restore/cluster-recovery.yaml
kubectl -n pg-trial-restore get cluster -w
```
Wait until ready (5–10분).

**Step 4: 복구 데이터 검증**

Run:
```bash
RESTORE_PRIMARY=$(kubectl -n pg-trial-restore get pod -l cnpg.io/cluster=pg-trial-pg,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
kubectl -n pg-trial-restore exec -it "$RESTORE_PRIMARY" -- \
  psql -U postgres -d demo -c "SELECT * FROM t ORDER BY id;"
```
Expected: 원본 cluster 의 데이터와 독립적으로 시점복구 데이터 확인.

**Step 5: 복구 정리**

Run: `kubectl delete ns pg-trial-restore`

**Step 6: 4.6b 소요 시간 박제**

Run:
```bash
echo "Task 4.6b 별도-namespace DR: $(date -Iseconds) · TARGET=${TARGET_TIME} · replay 소요 <min>분" \
  >> _workspace/cnpg-migration/05_pitr-drills.md
```
이 값이 Phase 9 `cnpg-dr-new-namespace.md` Runbook 의 근거.

## Task 4.7: PITR Runbook 초안 2건 작성 (v0.4 리뷰 C2 반영)

**Files:**
- Create: `docs/runbooks/postgresql/cnpg-pitr-restore.md` (Task 4.6a 기반 — 평시 PITR)
- Create: `docs/runbooks/postgresql/cnpg-dr-new-namespace.md` (Task 4.6b 기반 — DR replica)

**Step 1: cnpg-pitr-restore.md 작성** (Task 4.6a 의 5단계 PR 흐름)

구조: 증상(데이터 손상) → 진단(backup·WAL archive 최신 시각 확인) → **5단계 절차**(selfHeal off PR → cluster delete + PVC 정리 → bootstrap.recovery PR + sync → roles/database 재적용 확인 → bootstrap.recovery 제거 + selfHeal on PR) → 검증(psql 쿼리) → cleanup. design §8.2 절차를 그대로 복사.

PoC 단계 (pg-trial) 의 단순화와 Phase 6 이후 실제 프로젝트의 Git PR 경유 차이를 명시.

**Step 2: cnpg-dr-new-namespace.md 작성** (Task 4.6b 의 별도 namespace 복구)

구조: 사용 사례 (감사·compliance·원본 보존형 시점 스냅샷) → 사전 요구 (R2 credential re-seal) → 복구 Cluster 선언 → 검증 → cleanup.

**Step 3: 커밋**

Run:
```bash
git add docs/runbooks/postgresql/cnpg-pitr-restore.md \
        docs/runbooks/postgresql/cnpg-dr-new-namespace.md
git commit -m "docs(runbooks): add CNPG PITR + DR-namespace runbooks (phase 4 drills)"
```

## Task 4.8: Phase 4 완료 기록

Run:
```bash
echo "Phase 4 완료: $(date -Iseconds), PITR drill 성공" >> _workspace/cnpg-migration/00_phase-log.md
git add manifests/apps/pg-trial/*.yaml _workspace/cnpg-migration/00_phase-log.md
git commit -m "chore(cnpg): phase 4 backup + PITR verified"
git push origin main
```

---

# Phase 5: 모니터링 통합

## Task 5.1: Alloy scrape config 추가

**Files:**
- Modify: `manifests/monitoring/alloy/<config파일>` (실제 경로 확인 후)

**Step 1: 기존 Alloy config 파악**

Run: `grep -rn "kubernetes_sd_configs\|prometheus.scrape" manifests/monitoring/alloy/ | head`

**Step 2: CNPG job 추가**

Alloy 설정 파일(River syntax)에 다음 블록 추가 또는 기존 discovery에 relabel 추가:
```river
prometheus.scrape "cnpg" {
  targets = discovery.kubernetes.cnpg_pods.targets
  forward_to = [prometheus.remote_write.victoriametrics.receiver]
  job_name = "cnpg"
}

discovery.kubernetes "cnpg_pods" {
  role = "pod"
  selectors {
    role = "pod"
    field = "status.phase=Running"
  }
}

discovery.relabel "cnpg_pods" {
  targets = discovery.kubernetes.cnpg_pods.targets
  rule {
    source_labels = ["__meta_kubernetes_pod_label_cnpg_io_cluster"]
    action = "keep"
    regex = ".+"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_container_port_number"]
    action = "keep"
    regex = "9187"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_label_cnpg_io_cluster"]
    target_label = "cluster"
  }
}
```
> v0.4 리뷰 M2 반영: Phase 0 Task 0.4 Step 4 에서 기존 Alloy config 형식 (River vs Prometheus YAML) 을 박제. 위 예시는 River 형식. Phase 0 결과가 Prometheus YAML 이면 이 블록을 해당 형식으로 바꿔 작성하고, 반대의 경우 River 로 유지. **둘 다 제시하는 fallback 방식 폐기** — 운영자가 실행 시 어느 형식 쓸지 혼란 방지.

**Step 3: 커밋 + Alloy 재시작 대기 (ArgoCD selfHeal 또는 수동 sync)**

Run:
```bash
git add manifests/monitoring/alloy/
git commit -m "feat(alloy): scrape CNPG pod metrics on :9187"
git push origin main
argocd app sync alloy
```

## Task 5.1.1: operator 자체 메트릭 Service 보완 (리뷰 C3 조건부 신규)

> **리뷰 C3 반영**: Task 0.2 Step 3 의 `helm template` 사전 렌더에서 **operator 메트릭용 Service 가 자동 생성되지 않으면** 이 Task 수행. 자동 생성되면 skip.

**사전 판정 (Task 0.2 Step 3 결과 참조)**

Phase 0 의 `/tmp/cnpg-helm-rendered.yaml` 에서 다음 확인:
- `kind: Service` 중 `name: cnpg-controller-manager-metrics` 또는 유사 이름 존재 → **자동 생성**, 이 Task skip
- 없음 → 이 Task 수행 (메모리 `project_argocd_metrics_service_gap` 동일 패턴)

**Step 1: metrics-service.yaml 수동 작성**

**Files:**
- Create: `manifests/infra/cnpg-operator/metrics-service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: cnpg-controller-manager-metrics
  namespace: cnpg-system
  labels:
    app.kubernetes.io/name: cloudnative-pg
    app.kubernetes.io/component: manager-metrics
spec:
  type: ClusterIP
  ports:
    - name: metrics
      port: 8080
      targetPort: metrics         # chart 의 controller container port 이름 (실제 값 확인 후 치환)
      protocol: TCP
  selector:
    # chart 가 operator pod 에 적용한 label selector (helm-rendered.yaml 에서 확인)
    app.kubernetes.io/name: cloudnative-pg
    app.kubernetes.io/component: manager
```

> 실제 selector 와 targetPort 는 Phase 0 `cnpg-helm-rendered.yaml` 의 Deployment spec (`spec.template.metadata.labels` · `containers[].ports[]`) 에서 복사.

**Step 2: kustomization.yaml resources 에 추가**

```yaml
# manifests/infra/cnpg-operator/kustomization.yaml
resources:
  - namespace.yaml
  - metrics-service.yaml      # 리뷰 C3 대응 (chart 가 Service 자동 생성 안 하는 경우)
```

**Step 3: apply 검증**

Run:
```bash
git add manifests/infra/cnpg-operator/metrics-service.yaml manifests/infra/cnpg-operator/kustomization.yaml
git commit -m "feat(cnpg): add operator metrics Service (review C3, chart gap compensation)"
git push origin main
argocd app sync cnpg-operator

# Service + Endpoints 확인
kubectl -n cnpg-system get svc cnpg-controller-manager-metrics
kubectl -n cnpg-system get endpoints cnpg-controller-manager-metrics -o yaml | head -20
```
Expected: Service 존재 + Endpoints 에 operator pod IP 1개 이상.

## Task 5.2: VM에 메트릭 도착 검증 (Scrape 동작 확인)

> 메트릭 이름·목록은 Task 3.8 에서 이미 dump 완료. 이 Task는 **Alloy scrape → VM 저장** 경로가 실제로 동작하는지 확인 + **operator 자체 메트릭도 포함** (리뷰 C3 반영).

**Step 1: cluster pod 메트릭 PromQL 쿼리로 VM 저장 확인**

Run:
```bash
# Grafana Explore 또는 VM API
VM_SVC="http://<vm-svc>:8428"
curl -sG "${VM_SVC}/api/v1/query" --data-urlencode 'query=cnpg_collector_up' | jq '.data.result | length'
```
Expected: `1` 이상 (pg-trial cluster 결과).

**Step 2: cluster·namespace 라벨 확인 (Task 5.1 relabel 검증)**

Run:
```bash
curl -sG "${VM_SVC}/api/v1/query" --data-urlencode 'query=cnpg_collector_up' \
  | jq '.data.result[0].metric | {cluster, namespace, job}'
```
Expected: `cluster=pg-trial-pg`, `namespace=pg-trial`, `job=cnpg` 포함.

**Step 3: Task 3.8의 실존 메트릭 중 일부가 VM에 도착했는지 spot-check**

```bash
for m in cnpg_collector_up cnpg_collector_last_available_backup_timestamp; do
  cnt=$(curl -sG "${VM_SVC}/api/v1/query" --data-urlencode "query=$m" | jq '.data.result | length')
  echo "$m: $cnt series"
done
```
Expected: 각 ≥1. 0이면 scrape 설정 문제 → Task 5.1 relabel 재검토.

**Step 4: operator 자체 메트릭 scrape 확인 (리뷰 C3 반영 · design §10.1 약속 이행)**

operator pod 의 메트릭 (cnpg-system namespace · 포트 8080) 이 VM 에 도착하는지 확인. operator 메트릭은 `controller_runtime_*`, `workqueue_*` 등 kubebuilder/controller-runtime 계열.

```bash
# operator pod 메트릭 series 존재 확인
for m in controller_runtime_reconcile_total workqueue_depth go_goroutines; do
  cnt=$(curl -sG "${VM_SVC}/api/v1/query" \
    --data-urlencode "query=${m}{namespace=\"cnpg-system\"}" | jq '.data.result | length')
  echo "$m (cnpg-system): $cnt series"
done
```
Expected: 각 ≥1. 0이면:
- Task 5.1 Alloy scrape 설정이 cluster pod 9187 만 대상 → cnpg-system:8080 추가 필요 (selectors `namespace=cnpg-system` + `port=8080`)
- 또는 Task 5.1.1 metrics Service 가 없거나 selector 불일치

**Step 5: Alloy scrape config 에 operator job 추가 (Step 4 실패 시)**

기존 `prometheus.scrape "cnpg"` 블록 아래에 operator 전용 job 추가:
```river
prometheus.scrape "cnpg_operator" {
  targets = discovery.relabel.cnpg_operator.output
  forward_to = [prometheus.remote_write.victoriametrics.receiver]
  job_name = "cnpg-operator"
}

discovery.kubernetes "cnpg_operator_pods" {
  role = "pod"
  namespaces { names = ["cnpg-system"] }
}

discovery.relabel "cnpg_operator" {
  targets = discovery.kubernetes.cnpg_operator_pods.targets
  rule {
    source_labels = ["__meta_kubernetes_pod_container_port_number"]
    action = "keep"
    regex = "8080"
  }
}
```
Commit + argocd sync alloy → Step 4 재검증.

## Task 5.3: Grafana dashboard import

**Files:**
- Create: `manifests/monitoring/grafana/dashboards/cnpg-overview.json` (공식 dashboard JSON)

**Step 1: 공식 dashboard JSON 다운로드**

Phase 0 I-3에서 확인한 dashboard ID 기준:
```bash
curl -s "https://grafana.com/api/dashboards/<ID>/revisions/<REV>/download" \
  > manifests/monitoring/grafana/dashboards/cnpg-overview.json
```

**Step 2: VM 데이터소스 변수 치환 확인**

JSON 내부 `"datasource"` 필드가 홈랩 Prometheus/VM 데이터소스 UID와 일치하도록 편집.

**Step 3: Grafana ConfigMap/sidecar 방식에 맞게 label 또는 폴더 지정**

기존 Grafana 대시보드 프로비저닝 방식 (sidecar label 등) 확인 후 맞춤.

**Step 4: 커밋 + sync**

```bash
git add manifests/monitoring/grafana/dashboards/cnpg-overview.json
git commit -m "feat(grafana): add CNPG overview dashboard"
git push origin main
argocd app sync grafana
```

**Step 5: 브라우저 검증**

Grafana UI에서 대시보드 접근 → pg-trial cluster variable 선택 → 패널 데이터 렌더링 확인.

## Task 5.4: 알람 규칙 4종 추가

**Files:**
- Create 또는 Modify: `manifests/monitoring/grafana/alerts/cnpg.yaml` (또는 기존 alerting rules 파일)

**Step 1: 4개 알람 YAML**

```yaml
groups:
  - name: cnpg
    interval: 1m
    rules:
      - alert: CNPGCollectorDown
        expr: cnpg_collector_up == 0
        for: 5m
        labels:
          severity: critical
          category: database
        annotations:
          summary: "CNPG collector down for {{ $labels.cluster }}/{{ $labels.namespace }}"
          description: "Exporter not responding for 5m. Check pod health and NP egress."

      - alert: CNPGBackupTooOld
        expr: (time() - cnpg_collector_last_available_backup_timestamp) > 30 * 3600
        for: 10m
        labels:
          severity: warning
          category: database
        annotations:
          summary: "Last successful backup for {{ $labels.cluster }} > 30h old"
          description: "ScheduledBackup may be failing. Check ObjectStore CR status and plugin pod."

      - alert: CNPGWALArchiveStuck
        expr: cnpg_collector_pg_wal_archive_status{value="ready"} > 10
        for: 15m
        labels:
          severity: warning
          category: database
        annotations:
          summary: "WAL archive backlog on {{ $labels.cluster }} > 10 segments"

      # 리뷰 H5 반영: 정규식 매칭 대신 CNPG 가 PVC 에 자동 부여하는 `cnpg.io/cluster` 라벨 기반.
      # 향후 walStorage 분리 (<cluster>-wal-N) 도입해도 자동 커버.
      # kube-state-metrics 전제 (미도입 시 Phase 5 진입 전 추가 필요).
      - alert: CNPGPVCDiskPressure
        expr: |
          (kubelet_volume_stats_used_bytes
             / kubelet_volume_stats_capacity_bytes) > 0.8
          and on (namespace, persistentvolumeclaim)
            (kube_persistentvolumeclaim_labels{label_cnpg_io_cluster!=""} == 1)
        for: 15m
        labels:
          severity: warning
          category: database
        annotations:
          summary: "CNPG PVC {{ $labels.persistentvolumeclaim }} > 80% usage ({{ $labels.label_cnpg_io_cluster }})"
```

**Step 2: 실존 메트릭 검증 (각 expr 의 좌측 메트릭)**

Run:
```bash
for metric in cnpg_collector_up cnpg_collector_last_available_backup_timestamp cnpg_collector_pg_wal_archive_status; do
  echo "=== $metric ==="
  curl -sG "http://<vm-svc>:8428/api/v1/query" --data-urlencode "query=$metric" | jq -r '.data.result | length'
done
```
Expected: 각 > 0.

**Step 2a: kube-state-metrics + cnpg.io/cluster 라벨 실존 검증 (v0.4 리뷰 H5)**

`kube_persistentvolumeclaim_labels` 가 VM 에 있고, `label_cnpg_io_cluster` 라벨이 채워지는지 확인 — 없으면 `CNPGPVCDiskPressure` 알람이 평생 침묵.

```bash
# kube-state-metrics 배포 유무
kubectl get deploy -A | grep kube-state-metrics
# 없으면 Phase 5 진입 전 manifests/monitoring/ 하위에 kube-state-metrics 추가 필요

# PVC label 시리즈 확인
curl -sG "http://<vm-svc>:8428/api/v1/query" \
  --data-urlencode 'query=kube_persistentvolumeclaim_labels{label_cnpg_io_cluster!=""}' \
  | jq '.data.result | length'
```
Expected: ≥1 (pg-trial PVC).

**Step 2b: Task 3.8 metrics dump 에서 `cnpg_collector_pg_wal_archive_status` 의 실제 라벨 키 검증 (v0.4 리뷰 M8)**

```bash
grep -E "^cnpg_collector_pg_wal_archive_status\b" _workspace/cnpg-migration/10_cnpg-metrics.txt | head -5
# 또는 실제 /metrics 출력으로 라벨 확인
PRIMARY=$(kubectl -n pg-trial get pod -l cnpg.io/cluster=pg-trial-pg,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
kubectl -n pg-trial exec -it "$PRIMARY" -- curl -s http://localhost:9187/metrics \
  | grep "^cnpg_collector_pg_wal_archive_status" | head -5
```
Expected: 출력에 라벨 키가 `value`, `state`, 혹은 다른 이름인지 확인. 알람 expr 의 `{value="ready"}` 매칭자가 실제 라벨 키와 일치하는지 검증 후 필요 시 수정.

**Step 3: Telegram 라우팅 확인**

기존 `alert-engineer` 채널 포맷에 맞는지 검토.

**Step 4: 커밋 + sync**

```bash
git add manifests/monitoring/grafana/alerts/cnpg.yaml
git commit -m "feat(monitoring): add 4 CNPG alert rules (collector/backup/WAL/PVC)"
git push origin main
argocd app sync grafana
```

## Task 5.5: 알람 발화·라우팅 검증 (GitOps 경유, v0.4 리뷰 H4 반영)

> **리뷰 H4 반영**: v0.3 plan 은 Grafana UI 로 임시 rule 추가/삭제 — UI 변경은 Git 매니페스트 외부에 존재하여 state history 오염 + "잊고 안 지운 rule" 으로 영구 false positive 위험. **GitOps 일관성 유지**를 위해 Git PR 경유로 일시 rule 추가 → revert, 혹은 기존 rule 의 임계값 일시 하향 → 원복 방식으로 교체.
>
> design §10.4 의 "silence 로 라우팅만 검증" 옵션도 합리적 대안 — 이 Task 는 두 접근을 모두 제공.

### 옵션 A — GitOps 경유 즉시 발화 rule (Git PR)

**Step A-1: 즉시 발화 rule 을 별도 파일로 commit**

`manifests/monitoring/grafana/alerts/cnpg-test.yaml` (임시 파일, 검증 후 git revert):
```yaml
groups:
  - name: cnpg-test
    interval: 1m
    rules:
      - alert: CNPGTestFire
        expr: cnpg_collector_up == 1                 # 평상시 참 → 즉시 발화
        for: 0s
        labels: { severity: info, test: "true" }
        annotations: { summary: "CNPG test fire (delete me after verification)" }
```

kustomization.yaml 에 resources 로 추가 + commit:
```bash
git add manifests/monitoring/grafana/alerts/cnpg-test.yaml \
        manifests/monitoring/grafana/alerts/kustomization.yaml
git commit -m "test(monitoring): temporary alert to verify CNPG routing (revert after confirm)"
git push origin main
argocd app sync grafana
```

**Step A-2: 5분 이내 발화·Telegram 도착 확인**

```bash
# Grafana pod 로그에서 rule 평가 확인
kubectl -n monitoring logs deploy/grafana --tail=200 | grep -iE "CNPGTestFire|firing"
```
Expected: Telegram 채널에 `CNPG test fire` 메시지 1회.

**Step A-3: 원복 PR**

```bash
git revert HEAD    # 혹은 파일 직접 rm + kustomization.yaml 되돌리기
git push origin main
argocd app sync grafana
```
Alert state history 에 `test: "true"` 라벨로 남아 검색·필터링 가능. Git 매니페스트는 원상태.

### 옵션 B — Alertmanager amtool silence 기반 라우팅만 검증 (design §10.4)

Grafana alerting 을 amtool 로 시뮬레이션 (실제 발화 없이 라우팅만 검증):

**Step B-1: 테스트 라우팅**

```bash
# amtool 이 Grafana 내장이 아닌 별도 alertmanager 면 해당 endpoint 사용
# 홈랩은 Grafana unified alerting 기본이라 API 로 대체 가능
curl -X POST "http://grafana:3000/api/v1/provisioning/alert-rules/.../test" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"type":"alertmanager","labels":{"alertname":"CNPGTestFire","severity":"info"}}'
```
Expected: Telegram 에 dummy message 1회.

### 권장

옵션 A 가 "실제 Grafana rule 평가 경로" 까지 확인하므로 primary 로 사용. 옵션 B 는 rule 수정 없이 빠른 라우팅 smoke test 가 필요할 때.

어느 방식이든 **Grafana UI 직접 rule 추가·삭제 금지** (GitOps drift 방지).

## Task 5.6: Phase 5 완료 기록

Run:
```bash
echo "Phase 5 완료: $(date -Iseconds), 알람 4종 + 대시보드" >> _workspace/cnpg-migration/00_phase-log.md
git add _workspace/cnpg-migration/00_phase-log.md
git commit -m "chore(cnpg): phase 5 monitoring done"
git push origin main
```

---

# Phase 6: 첫 실제 프로젝트 전환

> 대상: 6개월 내 DB 사용 확정된 신규 프로젝트. 편의상 `<first-project>` 로 표기. Phase 7 자동화 전에 **수동으로** common/ 매니페스트 6종 작성하여 end-to-end 검증.

## Task 6.1: 대상 프로젝트 선정 + namespace 결정

**Files:** (결정 기록)
- Create: `_workspace/cnpg-migration/06_first-project.md`

**Step 1: 프로젝트 이름 · 서비스 구성 확정**

예시: project=`<first-project>`, services=`api` (owner), 시나리오 선택=1(공유) or 2(분리).

**Step 2: 기록 + 커밋**

Run:
```bash
git add _workspace/cnpg-migration/06_first-project.md
git commit -m "docs(cnpg): record first project migration target"
```

## Task 6.2: common/ 매니페스트 수동 작성 (v0.4 M11: NetworkPolicy 포함 9 파일 · P6 ResourceQuota 포함 시 10 파일)

**Files (all under `manifests/apps/<first-project>/common/`):**
- Create: `namespace.yaml`
- Create: `role-secrets.sealed.yaml`
- Create: `r2-backup.sealed.yaml`
- Create: `cluster.yaml`
- Create: `objectstore.yaml`
- Create: `scheduled-backup.yaml`
- Create: `database-shared.yaml` (시나리오-1) 또는 services/별 database.yaml (시나리오-2, common/ 밖)
- Create: `network-policy.yaml` (v0.4 리뷰 M11 신규)
- Create: `resource-quota.yaml` (v0.4 리뷰 P6 신규, 선택)
- Create: `kustomization.yaml`

**Step 1: Phase 3/4의 pg-trial 매니페스트를 `<first-project>`로 복사 + rename**

Run:
```bash
mkdir -p manifests/apps/<first-project>/common
cp manifests/apps/pg-trial/{namespace,cluster,objectstore,scheduled-backup}.yaml \
   manifests/apps/<first-project>/common/
# sed로 pg-trial → <first-project>, demo → <role-name>, 1Gi → 6Gi 등 치환
```

**Step 2: role SealedSecret 신규 생성 (kubeseal)**

각 role마다 랜덤 패스워드 생성 후 kubeseal append (Phase 3 Task 3.2 패턴).

**Step 3: r2-backup SealedSecret 신규 생성 (namespace-scoped)**

동일한 R2 credential을 새 namespace용으로 re-seal. 평문 파일은 tmp에서만 다루고 삭제.

**Step 4: Database CRD 작성**

시나리오별:
- 시나리오-1: `common/database-shared.yaml` 하나
- 시나리오-2: `services/<svc>/database.yaml` 각각

**Step 4.5: network-policy.yaml 작성 (v0.4 리뷰 M11 · design §D14 이행)**

design §D14 의 "egress: kube-dns + Cloudflare CIDR + 443" 약속을 매니페스트화. Cloudflare IP range 는 R2 등 외부 egress 에만 쓰이므로 postgres pod 만 대상.

```yaml
# manifests/apps/<first-project>/common/network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: <first-project>-pg-ingress-egress
  namespace: <first-project>
spec:
  podSelector:
    matchLabels:
      cnpg.io/cluster: <first-project>-pg    # CNPG 가 pod 에 자동 부여
  policyTypes: [Ingress, Egress]
  ingress:
    # 같은 namespace 앱 pod → TCP 5432
    - from:
        - podSelector: {}
      ports:
        - protocol: TCP
          port: 5432
    # monitoring Alloy → TCP 9187 (metrics)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 9187
  egress:
    # kube-dns (CoreDNS)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # R2 (Cloudflare) — 443. CIDR 정밀도 낮음 (§D14 솔직 기록)
    # TODO: Cloudflare IP range (https://www.cloudflare.com/ips-v4/) 월 1회 자동 갱신 CronJob 도입 시 ipBlock 로 전환.
    # 현재는 0.0.0.0/0:443 으로 느슨하게 허용.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
      ports:
        - protocol: TCP
          port: 443
    # plugin-barman-cloud (cnpg-system) gRPC — plugin pod → postgres pod 가 아니라, postgres pod → plugin Service
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: cnpg-system
      ports:
        - protocol: TCP
          # plugin gRPC port (실제 값은 plugin manifest 확인)
```

**Step 4.6: resource-quota.yaml 작성 (v0.4 리뷰 P6 신규, 선택)**

단일 노드 K3s · OrbStack 12Gi 환경에서 프로젝트별 메모리 상한 강제. design §11.2 의 5 프로젝트 안전선과 정합.

```yaml
# manifests/apps/<first-project>/common/resource-quota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: <first-project>-quota
  namespace: <first-project>
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    persistentvolumeclaims: "3"    # Cluster PVC 1 + WAL 향후 분리 여지 2
```

> scheduling Application 이 이미 ResourceQuota 를 모든 namespace 에 배포한다면 이 파일 생략 가능 — Phase 6 진입 전 `kubectl get resourcequota -A | grep <first-project>` 확인.

**Step 5: kustomization.yaml 집합 선언**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <first-project>
resources:
  - namespace.yaml
  - role-secrets.sealed.yaml
  - r2-backup.sealed.yaml
  - cluster.yaml
  - objectstore.yaml
  - scheduled-backup.yaml
  - database-shared.yaml       # 시나리오-1
  - network-policy.yaml        # v0.4 M11
  - resource-quota.yaml        # v0.4 P6 (scheduling Application 미적용 시)
```

**Step 6: 로컬 빌드 검증**

Run: `kubectl kustomize manifests/apps/<first-project>/common/ | head -60`

**Step 7: 커밋**

```bash
git add manifests/apps/<first-project>/common/
git commit -m "feat(<first-project>): add CNPG database manifests"
```

## Task 6.3: ArgoCD Application 선언 (v0.4 리뷰 P7 · ignoreDifferences 사전 준비)

**Files:**
- Create: `argocd/applications/apps/<first-project>.yaml`

**Step 1: Application YAML (기존 패턴 재사용 + ignoreDifferences 사전 틀)**

sync wave, selfHeal, prune 등 다른 apps 참고하여 일관성 유지. 추가로 **v0.4 리뷰 P7 반영** — CNPG operator 가 Cluster CR 에 default 값 자동 채움 (`encoding`, `monitoring.disableDefaultQueries` 등) 으로 drift 가능성. 메모리 `project_traefik_helm_v39_gomemlimit_ssa` 패턴 재현 우려.

초기엔 `ignoreDifferences` 블록을 **주석 처리된 placeholder** 로 두고, Phase 6 Task 6.4 Step 3 실제 sync 후 drift 관찰 결과에 따라 실제 경로를 채운다:

```yaml
# argocd/applications/apps/<first-project>.yaml (발췌)
spec:
  # v0.4 P7: CNPG operator 가 spec 자동 채움 가능한 필드 — Phase 6.4 관찰 후 활성화.
  # 주요 후보:
  # - .spec.bootstrap.initdb.encoding (operator default UTF8)
  # - .spec.monitoring.disableDefaultQueries (operator default false)
  # - .spec.managed.roles[].passwordSecret (회전 후 spec 변경)
  # ignoreDifferences:
  #   - group: postgresql.cnpg.io
  #     kind: Cluster
  #     name: <first-project>-pg
  #     namespace: <first-project>
  #     jqPathExpressions:
  #       - '.spec.bootstrap.initdb.encoding'
  #       - '.spec.monitoring.disableDefaultQueries'
```

**Step 2: apps AppProject 화이트리스트 엄격 검증 (v0.4 리뷰 H1 반영)**

Task 0.7 Step 1a 판정 재확인:
```bash
kubectl -n argocd get appproject apps -o yaml | yq '.spec.namespaceResourceWhitelist'
```

- `null` 또는 필드 부재 → 모든 namespace 리소스 허용 — Phase 6 sync 진행 가능.
- 값 존재 → `postgresql.cnpg.io/*` + `barmancloud.cnpg.io/*` 등재 확인. 없으면 Phase 2.0 의 PR 에 apps AppProject 도 포함시켰어야 함. 누락이라면 지금이라도 PR 추가 후 merge + argocd sync 대기.

Dry-run sync 로 사전 검증:
```bash
argocd app sync <first-project> --dry-run | grep -E "is not permitted|Resource"
```
에러 문자열 0건이어야 함.

**Step 3: 커밋 + push**

```bash
git add argocd/applications/apps/<first-project>.yaml
git commit -m "feat(argocd): add <first-project> application"
git push origin main
```

## Task 6.4: sync + end-to-end 검증

**Step 1: ArgoCD sync**

Run: `argocd app sync <first-project> --prune`

**Step 2: Cluster · Database ready 대기**

Run: `kubectl -n <first-project> get cluster,database -w`

**Step 3: 앱 Deployment에 D7 env 블록 추가 (app 레포 측 작업)**

이 Phase에서는 아직 setup-app 자동화 안 됐으므로 **수동**으로 app deployment.yaml에 env 블록 주입.

**Step 3a: Cluster CR drift 관찰 (v0.4 리뷰 P7 신규)**

sync 후 ArgoCD Application 이 OutOfSync 로 전환되는지 확인 — drift 필드 식별:

```bash
# 1분 대기 후
argocd app diff <first-project> 2>&1 | grep -E "^==|^\s+" | head -30

# 또는
kubectl -n argocd get application <first-project> -o jsonpath='{.status.conditions}' | jq
```

drift 관찰되는 필드 (예: `.spec.bootstrap.initdb.encoding`, `.spec.monitoring.disableDefaultQueries`) 를 기록한 뒤, Task 6.3 Application YAML 의 `ignoreDifferences` 블록 주석 제거 + 실제 jqPathExpression 채워서 PR 제출. merge 후 OutOfSync 해제 확인.

**Step 4: 앱 pod가 DB 연결 성공 로그 확인 (부수 증거)**

Run:
```bash
kubectl -n <first-project> logs deploy/<api-deployment> | grep -i "connect\|database" | tail -20
```
Expected: DB 연결 성공 로그. (**이것만으로는 충분치 않음** — Step 5에서 실제 write/read 검증.)

**Step 5: DB write/read 실제 동작 검증 (핵심 · v0.4 리뷰 M7: sslmode 단계별)**

임시 psql client로 role 권한·DB schema 적용·write/read 왕복 확인. sslmode 를 `disable` → `require` 순차 테스트 — require 실패 시 원인 분리 (네트워크·인증서 둘 중 어느 계층).

```bash
NS=<first-project>
CLUSTER=<first-project>-pg
ROLE=<owner-role-name>      # e.g. api
DB=<db-name>                # e.g. api 또는 wiki

PASS=$(kubectl -n "$NS" get secret "${CLUSTER}-${ROLE}-credentials" -o jsonpath='{.data.password}' | base64 -d)

# 5-1: sslmode=disable (plain TCP) — 인증·네트워크 기본 동작 확인용
kubectl -n "$NS" run psql-verify-plain --rm -it --restart=Never \
  --image=postgres:16-alpine \
  --env="PGPASSWORD=${PASS}" \
  --command -- \
  psql "postgresql://${ROLE}@${CLUSTER}-rw:5432/${DB}?sslmode=disable" -c "SELECT 1;"
```

`disable` 통과하면:
- 인증 OK, 네트워크 OK (Cluster IP 도달 가능)
- sslmode=require 실패 시는 TLS 계층 문제 국한

```bash
# 5-2: sslmode=require (운영 기본)
kubectl -n "$NS" run psql-verify --rm -it --restart=Never \
  --image=postgres:16-alpine \
  --env="PGPASSWORD=${PASS}" \
  --command -- \
  psql "postgresql://${ROLE}@${CLUSTER}-rw:5432/${DB}?sslmode=require" -c "
    CREATE TABLE IF NOT EXISTS verify_t(id serial primary key, v text, created_at timestamptz default now());
    INSERT INTO verify_t(v) VALUES('write-test-' || now()::text) RETURNING *;
    SELECT count(*) AS total FROM verify_t;
  "
```
Expected: CREATE 성공 · INSERT 1 row RETURNING · COUNT ≥ 1.

**실패 시 역추적 가이드**:
- 5-1 도 실패 → role password 불일치 (secret 데이터 참조) 또는 네트워크 (NetworkPolicy egress 막힘)
- 5-1 성공·5-2 실패 → TLS 계층. `psql --echo-all` 로 TLS handshake 에러 메시지 확인, CNPG operator CA 자동 생성 확인.
- 5-2 도 성공 → 운영 기본 경로 정상.

**Step 6: 시나리오 검증 (공유 vs 분리)**

- **시나리오-1 (공유 DB)**: 두 서비스가 동일 secret을 참조해 같은 DB에 read/write 가능 — psql-verify 를 두 번 실행해서 교차 확인
- **시나리오-2 (분리 DB)**: 각 서비스가 자기 role의 DB에만 접근, **다른 DB에 접근 실패 확인**:
  ```bash
  # api role이 scraper DB에 접근 시도 → permission denied 기대
  kubectl -n "$NS" run psql-deny-test --rm -it --restart=Never \
    --image=postgres:16-alpine \
    --env="PGPASSWORD=${API_PASS}" \
    --command -- \
    psql "postgresql://api@${CLUSTER}-rw:5432/scraper?sslmode=require" -c "SELECT 1;"
  ```
  Expected: `FATAL: permission denied for database "scraper"` 또는 유사 에러.

## Task 6.5: 다른 더미 프로젝트로 반대 시나리오 검증

Task 6.2–6.4를 `pg-demo` 더미 프로젝트로 반복하되 **반대 시나리오** 적용. 첫 프로젝트가 시나리오-1이었으면 이번엔 시나리오-2.

## Task 6.6: Phase 6 완료 기록

```bash
echo "Phase 6 완료: $(date -Iseconds), 시나리오-1·2 end-to-end 검증" >> _workspace/cnpg-migration/00_phase-log.md
git commit -am "chore(cnpg): phase 6 first real project migrated"
git push origin main
```

---

# Phase 7: setup-app 자동화 확장

> 목표: `.app-config.yml` 의 `database` 블록만으로 Phase 6의 수동 작업이 자동 생성되게.

## Task 7.1: `.app-config.yml` 스키마 하위호환 검증 (M9)

**Files:**
- Create: `_workspace/cnpg-migration/07_appconfig-diff.md`

**Step 1: 기존 앱 `.app-config.yml` 스키마 덤프**

Run:
```bash
# 외부 앱 레포들 (ukkiee-dev/*) 순회
for repo in test-web homepage adguard uptime-kuma; do
  gh api "repos/ukkiee-dev/$repo/contents/.app-config.yml" --jq '.content' | base64 -d > "/tmp/app-config-$repo.yml" 2>/dev/null || true
done
ls -la /tmp/app-config-*.yml
```

**Step 2: 기존 스키마 필드 목록화 · database 키 미충돌 확인**

Run:
```bash
for f in /tmp/app-config-*.yml; do
  echo "=== $f ==="
  yq 'keys' "$f"
done
```
Expected: 어떤 앱도 `database` 키를 이미 사용하지 않음.

**Step 3: 결과 기록**

`_workspace/cnpg-migration/07_appconfig-diff.md` 에 현재 스키마 · 추가 필드 · parser 영향 평가 기록.

## Task 7.2: `_sync-app-config.yml` 파서에 `database` 블록 추가

**Files:**
- Modify: `.github/workflows/_sync-app-config.yml`

**Step 1: 파서 로직 분석**

Run: `grep -n "yq\|jq\|fromYaml" .github/workflows/_sync-app-config.yml | head`

**Step 2: database 블록 처리 step 추가**

workflow에 `database.enabled`·`database.services[]` 읽어서 env/param으로 내려주는 step 추가.

**Step 3: 기존 앱에 영향 없음 테스트**

Run: `gh workflow run _sync-app-config.yml --ref <test-branch> -f app=test-web` → 기존 homepage/adguard/uptime 의 매니페스트에 변경 없음 확인.

**Step 4: 커밋**

```bash
git add .github/workflows/_sync-app-config.yml
git commit -m "feat(workflow): parse database block in .app-config.yml"
```

## Task 7.3: `.github/templates/cnpg/` 템플릿 파일 생성

**Files (all under `.github/templates/cnpg/`):**
- Create: `cluster.yaml.tpl`
- Create: `objectstore.yaml.tpl`
- Create: `scheduled-backup.yaml.tpl`
- Create: `database.yaml.tpl`
- Create: `role-secret.yaml.tpl`
- Create: `r2-backup-secret.yaml.tpl`
- Create: `deployment-env-patch.yaml.tpl`
- Create: `network-policy.yaml.tpl` (v0.4 리뷰 M11 · Task 6.2 Step 4.5 의 NP 템플릿화)

**Step 1: Phase 6에서 쓴 수동 매니페스트를 placeholder 치환 형태로 템플릿화**

예: `cluster.yaml.tpl`:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: __APP__-pg
  namespace: __APP__
  labels:
    app.kubernetes.io/part-of: __APP__
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:__PG_VERSION__
  storage: { size: __STORAGE__, storageClass: local-path }
  resources:
    requests: { cpu: 100m, memory: 384Mi }
    limits:   { cpu: 1000m, memory: 1Gi }
  monitoring:
    enablePodMonitor: false
  managed:
    roles: []    # 이후 role별 yq 병합
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: __APP__-backup
        serverName: __APP__-pg
```

**Step 2: 나머지 템플릿도 동일 패턴**

**Step 3: 커밋**

```bash
git add .github/templates/cnpg/
git commit -m "feat(templates): add CNPG manifest templates for setup-app"
```

## Task 7.4: `setup-app/database/action.yml` 서브 composite action 작성

**Files:**
- Create: `.github/actions/setup-app/database/action.yml`

**Step 1: 입력 정의**

```yaml
name: Setup CNPG Database for App
description: Generate Cluster + Database + role SealedSecret for <app>
inputs:
  app-name:       { required: true }
  service-name:   { required: false, default: "" }
  mode:           { required: true, description: "owner | reference | none" }
  db-name:        { required: false, default: "" }
  ref-db:         { required: false, default: "" }
  pg-version:     { required: false, default: "16" }
  # v0.4 리뷰 M9 반영: local-path resize 미지원 (D 시나리오) 환경에서 초기 default 를 보수적으로 10Gi 상향.
  # R2 비용은 retention 14d 기준 미미. OpenEBS 전환 후 resize 쉬워지면 default 재평가 가능.
  # app owner 가 더 작게 필요하면 .app-config.yml database.storage 로 5Gi 명시 가능.
  storage:        { required: false, default: "10Gi", description: ".app-config.yml database.storage 로 override. D 시나리오 확정 (local-path resize 미지원) 반영 · v0.4 M9 반영 10Gi 상향" }
  kubeconfig:     { required: true, description: "kubeseal cert fetch용" }
```

**Step 2: composite steps**

1. common/ 없으면 초기화: cluster.yaml·objectstore.yaml·scheduled-backup.yaml·r2-backup.sealed.yaml 복사 + placeholder 치환 (sed)
2. mode=owner면:
   - 랜덤 password 생성: `openssl rand -base64 24`
   - role-secret.yaml stringData 템플릿 채우고 → kubeseal (ARC runner in-cluster)
   - 기존 role-secrets.sealed.yaml에 append
   - cluster.yaml의 managed.roles 배열에 **idempotent yq 병합** (v0.4 리뷰 M4 반영):
     ```yaml
     # 단순 append 는 재실행 시 중복. unique_by(.name) 로 idempotent.
     yq eval -i '
       .spec.managed.roles = (
         (.spec.managed.roles // []) + [{
           "name": env(ROLE_NAME),
           "ensure": "present",
           "login": true,
           "passwordSecret": { "name": env(SECRET_NAME) }
         }]
         | unique_by(.name)
       )
     ' manifests/apps/${APP}/common/cluster.yaml
     ```
     동일 role 이름으로 workflow 재실행해도 중복 entry 없음 — 마지막 값이 유지됨 (yq unique_by 는 "처음" 것 유지이므로, "마지막 입력이 덮어쓰기" 가 필요하면 `reverse | unique_by(.name) | reverse` 패턴 사용).
   - Database CRD 생성 (common/ 또는 services/<svc>/)
3. mode=reference면: Database CRD 생성 안 함, Deployment envFrom은 ref role credentials 참조
4. Deployment env 패치: yq로 D7 패턴 env 배열 주입

**Step 3: 로컬 dry-run 검증 (act 또는 실제 workflow_dispatch)**

Run:
```bash
# 드라이런용 테스트 앱
gh workflow run _create-app.yml \
  --ref <test-branch> \
  -f app-name=pg-automation-test \
  -f database-enabled=true \
  -f database-mode=owner \
  -f database-name=api
```

**Step 4: 결과 매니페스트 검증**

생성된 `manifests/apps/pg-automation-test/` 구조 확인:
- common/ 6종 파일
- services/api/database.yaml (owner일 때)
- deployment.yaml 에 env 블록 포함

**Step 5: 커밋**

```bash
git add .github/actions/setup-app/database/
git commit -m "feat(setup-app): add database sub-composite for CNPG provisioning"
```

## Task 7.5: `_create-app.yml` caller에 database step 통합

**Files:**
- Modify: `.github/workflows/_create-app.yml`

**Step 1: database-enabled 입력 + step 호출**

기존 flat/monorepo 분기 후에 database step 추가:
```yaml
- name: Setup database (CNPG)
  if: ${{ inputs.database-enabled == 'true' }}
  uses: ./.github/actions/setup-app/database
  with:
    app-name:     ${{ inputs.app-name }}
    service-name: ${{ inputs.service-name }}
    mode:         ${{ inputs.database-mode }}
    db-name:      ${{ inputs.database-name }}
    ref-db:       ${{ inputs.database-ref }}
    # ...
```

**Step 2: 커밋 + push**

```bash
git add .github/workflows/_create-app.yml
git commit -m "feat(workflow): integrate database step in _create-app"
git push origin main
```

## Task 7.6: end-to-end 자동화 테스트

**Step 1: 새 테스트 앱 setup-app 실행**

Run:
```bash
gh workflow run setup-app.yml \
  -f app-name=pg-auto-demo \
  -f type=static \
  -f subdomain=pg-auto-demo \
  -f database-enabled=true \
  -f database-mode=owner \
  -f database-name=api
```

**Step 2: ArgoCD sync → DB ready → app pod 연결 성공까지 타이머 측정**

Expected: <5분 이내 Ready.

**Step 3: teardown으로 rollback 검증**

Run: `gh workflow run teardown.yml -f app=pg-auto-demo`
Expected: namespace·ArgoCD App·GHCR·DNS/Tunnel 깨끗이 정리. PVC·SealedSecret 포함.

## Task 7.7: Renovate packageRules 추가 (M10)

**Files:**
- Modify: `renovate.json`

**Step 1: CNPG·plugin·cert-manager·postgres image 관련 rule 추가**

```json
{
  "packageRules": [
    {
      "matchDatasources": ["helm"],
      "matchPackageNames": ["cloudnative-pg", "cert-manager"],
      "major": { "enabled": false },
      "automerge": false
    },
    {
      "matchDatasources": ["docker"],
      "matchPackageNames": ["ghcr.io/cloudnative-pg/postgresql"],
      "minor": { "automerge": true },
      "major": { "enabled": false }
    },
    {
      "matchDatasources": ["github-releases"],
      "matchPackageNames": ["cloudnative-pg/plugin-barman-cloud"],
      "automerge": false
    }
  ]
}
```

**Step 2: 커밋**

```bash
git add renovate.json
git commit -m "chore(renovate): add rules for CNPG operator/plugin/cert-manager/postgres image"
git push origin main
```

## Task 7.8: Phase 7 완료 기록

```bash
echo "Phase 7 완료: $(date -Iseconds), setup-app 자동화" >> _workspace/cnpg-migration/00_phase-log.md
git commit -am "chore(cnpg): phase 7 automation done"
git push origin main
```

---

# Phase 8: Bitnami 폐기 (v0.4 A1 전면 재설계)

> **v0.4 변경 이유**: I-0 팩트체크 결과 Bitnami StatefulSet/Service/PVC 는 `helm install` 직접 배포되어 ArgoCD 관리 밖. v0.3 의 "ArgoCD Application 삭제 cascade" 로는 제거 불가 → `helm uninstall` 선행 필요.

## Task 8.0: 사전 조건 확인 (v0.4 신규 · 리뷰 H6 엄격 게이트 확장)

> **리뷰 H6 반영**: Phase 8 의 `helm uninstall` + PVC delete 는 reclaim Delete 정책으로 PV 및 hostPath 데이터 **영구 삭제**. 복구 자체 불가능. 이 단계의 사전 검증 강도는 다른 Phase 의 5배 이상이어야 함. 2줄 체크박스를 엄격 체크리스트로 확장.

**Step 1: CNPG 운영 실적 확인**

Run:
```bash
# CNPG 도입 이후 최소 30일 안정 운영 확인
argocd app get <project-pg-app-name> | grep -E "Health|Sync"
kubectl -n <project> get cluster <project>-pg -o jsonpath='{.status.conditions}'
```
Expected: 30일 이상 Healthy · `CNPGCollectorDown` false positive 0.

**Step 2: I-0a 결정 재확인**

Read `_workspace/cnpg-migration/13_bitnami-drift-decision.md` — 옵션 (α) 채택 확인.

**Step 3: 엄격 사전 조건 체크리스트 (v0.4 H6 신규)**

아래 10개 항목을 **모두 ✅** 이어야 Task 8.2 로 진행. 하나라도 미확인이면 보류.

- [ ] **마지막 백업 무결성 검증 통과**: Task 8.2 Step 4 `pg_restore --list` 결과가 에러 없이 목차 출력. 박제: `_workspace/cnpg-migration/17_final-backup-integrity.md`
- [ ] **R2 archive prefix SHA256 + 파일 크기 기록**: `rclone hashsum SHA256 r2:homelab-postgresql-backup/archive-$(date -u +%Y%m%d)/` 출력 + `rclone size` 박제
- [ ] **외장 SSD 추가 보관** (R2 의존성 제거): `cp /tmp/<latest>.dump /Volumes/ukkiee/backups/cnpg-phase8/` 후 `shasum -a 256` 파일 해시 일치 확인
- [ ] **data-postgresql-0 PV hostPath + 사용량 박제**: PV 의 `spec.local.path` 또는 `spec.hostPath.path` 확인, `kubectl -n apps exec -it <bitnami-pod> -- du -sh /bitnami/postgresql/data` 출력 기록
- [ ] **운영자 self-review: 실사용 0건 재확인**: Bitnami 인스턴스에서 마지막 30일 사용자 쿼리 집계
  ```bash
  kubectl -n apps exec -it <bitnami-pod> -- psql -U postgres -c "
    SELECT schemaname, relname, n_live_tup, last_autoanalyze
    FROM pg_stat_user_tables
    WHERE schemaname NOT IN ('pg_catalog', 'information_schema');
  "
  ```
  n_live_tup 이 의미 없는 값인지 확인, 출력을 `_workspace/cnpg-migration/17_final-backup-integrity.md` 에 박제
- [ ] **CNPG 30일 안정 운영 증거**: 알람 false positive 0 · 백업 성공률 30/30 · PVC 사용률 안정 그래프 (스크린샷 또는 Grafana JSON 저장)
- [ ] **참조 0건 grep 재확인 (Task 8.1 결과)** — 시간 경과 후 회귀 없음
- [ ] **pvc reclaim policy 사전 파악 + Retain patch 결정**: 아래 Step 4 참조
- [ ] **로컬 도구 준비**: `rclone`, `pg_restore`, `shasum` 실행 가능
- [ ] **주 1회 점검 시점 (월요일 오전) 이 아니라 즉시 폐기 정당성**: 운영자 일정상 폐기 직후 문제 발생 시 복구 시간 확보 가능한가?

**Step 4: PVC reclaim policy 를 Retain 으로 일시 변경 (v0.4 H6 신규 · 안전 마진)**

Phase 8.4 의 `kubectl -n apps delete pvc data-postgresql-0` 이후 reclaim Delete 이면 PV 즉시 삭제 = hostPath 디렉토리 자동 정리. 운영자 실수로 다른 PVC 삭제 시 즉시 복구 불가.

**대안**: PVC 삭제 전 PV 의 reclaim policy 를 Retain 으로 patch — PVC 삭제 후 PV 는 남음 → 30일 후 수동 PV 삭제.

```bash
PV_NAME=$(kubectl -n apps get pvc data-postgresql-0 -o jsonpath='{.spec.volumeName}')
echo "PV to protect: $PV_NAME"
kubectl patch pv "$PV_NAME" --type merge \
  --patch '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
kubectl get pv "$PV_NAME" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'
# Expected: Retain
```

Task 8.4 Step 1 직전에 이 patch 를 수행하도록 (아래 Task 8.4 수정 참조).

**Step 5: 사전 조건 체크리스트 완료 박제**

```bash
cat > _workspace/cnpg-migration/17_final-backup-integrity.md <<'EOF'
# Phase 8 사전 조건 체크리스트 (H6 엄격 게이트)

- 실행 일자: <YYYY-MM-DD>
- 운영자: <name>

## 10개 체크박스 (모두 ✅ 인 경우에만 Task 8.1 진행)
[...위 Step 3 의 10개 체크박스 복사하여 실제 증거 링크·값 채움...]

## Retain patch 실행 결과 (Step 4)
- PV 이름: <PV_NAME>
- patch 이전: Delete
- patch 이후: Retain
- 검증 일자: <YYYY-MM-DD HH:MM UTC>

## 30일 후 PV 수동 삭제 예정
- Target date: <YYYY-MM-DD> (지금 + 30일)
- 알림 방법: GitHub Issue 또는 Runbook 메모
EOF

git add _workspace/cnpg-migration/17_final-backup-integrity.md
git commit -m "docs(cnpg): phase 8 H6 strict pre-conditions + evidence"
```

## Task 8.1: 최종 의존 참조 0건 확인

**Step 1: 전방위 grep**

Run:
```bash
grep -rn "postgresql-auth\|postgresql\.apps\|manifests/apps/postgresql" \
  manifests/ argocd/ .github/ --include="*.yaml" --include="*.yml" --include="*.sh"
```
Expected: `manifests/apps/postgresql/` 내부 self-reference + `backup-cronjob.yaml` 내 자가 참조만 존재.

**Step 2: 클러스터 런타임 참조 확인**

Run:
```bash
kubectl get pods -A -o json | jq '[.items[].spec.containers[].envFrom[]?.secretRef.name, .items[].spec.containers[].env[]?.valueFrom?.secretKeyRef?.name] | unique | map(select(. == "postgresql-auth"))'
```
Expected: `[]` 빈 배열.

**Step 3: 호스트 이름 참조 확인**

Run:
```bash
kubectl get pods -A -o yaml | grep -E "postgresql\.apps\.svc|postgresql-hl|postgresql-metrics"
```
Expected: backup CronJob 만 참조.

## Task 8.2: 마지막 백업 보존 + 무결성 검증 (v0.4 M5 보강)

**Step 1: CronJob suspend**

Run:
```bash
kubectl -n apps patch cronjob postgresql-backup --type merge --patch '{"spec":{"suspend":true}}'
kubectl -n apps get cronjob postgresql-backup
```

**Step 2: 마지막 수동 dump 실행**

```bash
kubectl -n apps create job --from=cronjob/postgresql-backup postgresql-final-dump
# 완료 대기
kubectl -n apps wait --for=condition=complete job/postgresql-final-dump --timeout=10m
kubectl -n apps logs job/postgresql-final-dump --tail=50
```

**Step 3: R2 archive prefix 로 복사 보존**

```bash
rclone copy \
  r2:homelab-postgresql-backup/daily/ \
  r2:homelab-postgresql-backup/archive-$(date -u +%Y%m%d)/ \
  --include "*-$(date -u +%Y%m%d)T*.dump" \
  --include "globals-$(date -u +%Y%m%d)T*.sql"
```

**Step 4: 백업 무결성 검증 (v0.4 신규)**

Run:
```bash
# 최신 dump 파일 목차 검증
LATEST=$(rclone lsf r2:homelab-postgresql-backup/archive-$(date -u +%Y%m%d)/ | grep -E "\.dump$" | head -1)
rclone copy "r2:homelab-postgresql-backup/archive-$(date -u +%Y%m%d)/$LATEST" /tmp/
pg_restore --list "/tmp/$LATEST" | head -20
```
Expected: 테이블/인덱스 목차 출력. 에러 시 **Phase 8 중단** + 원인 조사.

## Task 8.3: Helm release uninstall (v0.4 A1 핵심 단계)

**Step 1: Helm release 현황 확인**

Run:
```bash
helm list -n apps
kubectl -n apps get pvc data-postgresql-0 -o jsonpath='{.spec.volumeName}{"\n"}'
kubectl -n apps get pv <pv-name> -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'
```
Expected: `postgresql-18.5.15 deployed` · PVC volumeName 기록 · reclaim policy 확인.

**Step 2: Helm uninstall 실행 (v0.4 리뷰 H6 — 명시적 confirmation 추가)**

```bash
# v0.4 H6 반영: 영구 손실 단계 직전 operator 확인 prompt
PV_NAME=$(kubectl -n apps get pvc data-postgresql-0 -o jsonpath='{.spec.volumeName}')
PV_SIZE=$(kubectl -n apps get pvc data-postgresql-0 -o jsonpath='{.spec.resources.requests.storage}')
PV_PATH=$(kubectl get pv "$PV_NAME" -o jsonpath='{.spec.local.path}{.spec.hostPath.path}')
PV_POLICY=$(kubectl get pv "$PV_NAME" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')

cat <<EOF
===============================================================================
Phase 8.3 — Bitnami PostgreSQL 영구 삭제 직전 확인

PVC:              data-postgresql-0
PV 이름:          $PV_NAME
PV 크기:          $PV_SIZE
hostPath/local:   $PV_PATH
reclaim policy:   $PV_POLICY    (Retain 이어야 안전)

Task 8.0 Step 3 체크리스트 10개 모두 통과했는가?
_workspace/cnpg-migration/17_final-backup-integrity.md 박제 완료했는가?

이 단계 이후 복구는 외장 SSD 보관 dump + R2 archive 외 없음.
===============================================================================
EOF

read -p "계속 진행? (yes/no): " ans
[ "$ans" = "yes" ] || { echo "abort"; exit 1; }

helm uninstall postgresql -n apps
```

**Step 3: Bitnami 잔존 리소스 확인**

Run:
```bash
kubectl -n apps get sts,svc,pvc,secret | grep -iE "postgresql|sh.helm.release.v1.postgresql"
```
Expected: Helm 이 관리하던 StatefulSet/Service/ServiceAccount 는 삭제되고 **PVC (`data-postgresql-0`) 와 Helm release secret 일부만 잔존** 가능.

**Step 4: drift 리소스 수동 정리**

`postgresql-metrics` Service 는 2d 3h 전 생성된 drift 리소스 — Helm release 에 없을 수 있음:
```bash
kubectl -n apps delete svc postgresql-metrics 2>/dev/null || true
kubectl -n apps delete svc postgresql postgresql-hl 2>/dev/null || true
```

## Task 8.4: ArgoCD Application + 잔존 리소스 정리

**Step 0: PV reclaim policy → Retain patch (v0.4 리뷰 H6 신규 · 안전 마진)**

Task 8.0 Step 4 에서 이미 patch 했는지 재확인:
```bash
PV_NAME=$(kubectl -n apps get pvc data-postgresql-0 -o jsonpath='{.spec.volumeName}')
kubectl get pv "$PV_NAME" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'
# Expected: Retain
```
Delete 상태면 patch 재실행:
```bash
kubectl patch pv "$PV_NAME" --type merge \
  --patch '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

**Step 1: `data-postgresql-0` PVC 수동 삭제**

Run:
```bash
kubectl -n apps delete pvc data-postgresql-0
# PV 는 Retain 으로 patch 했으므로 **삭제되지 않고 Released 상태로 남음**
kubectl get pv "$PV_NAME"
```
Expected: PV status = `Released`, hostPath 디렉토리 물리적으로 유지.

**Step 1.5: PV 수동 삭제 예정일 기록 (v0.4 H6 신규)**

30일 후 데이터 완전 폐기 일정을 GitHub Issue 로 등록:
```bash
gh issue create \
  --title "[cnpg-phase8] Bitnami PV $PV_NAME 수동 삭제 (30d mark)" \
  --body "Phase 8 uninstall 완료: $(date -u +%Y-%m-%d). 30일 후 PV $PV_NAME 및 hostPath $PV_PATH 수동 삭제 예정.

## 삭제 명령
\`\`\`bash
kubectl delete pv $PV_NAME
# hostPath 는 K3s 노드 직접 접근 후 rm -rf
\`\`\`

## 사전 확인
- CNPG 운영 추가 60일 무장애 (누적 90일)
- 외장 SSD dump + R2 archive 둘 다 건재
- \`_workspace/cnpg-migration/17_final-backup-integrity.md\` 재검증 통과" \
  --label "cnpg-migration,phase-8" \
  --milestone "OpenEBS LocalPV migration"
```

**Step 2: 잔존 Secret 정리**

Run:
```bash
kubectl -n apps delete secret postgresql-auth 2>/dev/null || true
kubectl -n apps delete secret sh.helm.release.v1.postgresql.v1 sh.helm.release.v1.postgresql.v2 2>/dev/null || true
```

**Step 3: ArgoCD Application + 매니페스트 디렉토리 삭제**

```bash
git rm argocd/applications/apps/postgresql.yaml
git rm -r manifests/apps/postgresql/
git commit -m "chore(postgresql): retire Bitnami helm release and backup CronJob"
git push origin main
```

ArgoCD Application cascade 삭제:
```bash
argocd app delete postgresql --cascade --yes
```

**Step 4: external-ssd PVC 처리 결정 (v0.4 신규)**

옵션 선택:
- (i) **유지 (권장)**: `postgresql-backups-ssd` (20Gi, external-ssd) 를 §16 후속 "외장 SSD R2 mirror" 용으로 재활용. 이 경우 PVC 는 남기고 매니페스트 경로만 이동 필요.
- (ii) **즉시 삭제**: `kubectl -n apps delete pvc postgresql-backups-ssd` + 외장 SSD (`/Volumes/ukkiee/backups`) 디렉토리 수동 정리.

결정은 `_workspace/cnpg-migration/16_phase8-ssd-retention.md` 박제.

**Step 5: R2 archive prefix 장기 보관 정책 확인**

`homelab-postgresql-backup` 버킷 lifecycle 정책 확인:
- `daily/`, `weekly/`, `monthly/` 는 기존 retention 대로 자동 정리
- `archive-YYYYMMDD/` 는 **lifecycle 정책 미적용** → 별도 수동 삭제 원칙 (보존 기간은 운영자 판단)

## Task 8.5: `backup.sh` · Renovate · README 업데이트

**Files:**
- Modify: `backup.sh` (postgres 관련 블록 제거)
- Modify: `.github/renovate.json` (postgres-backup 이미지 규칙 검토)
- Modify: `.github/workflows/build-postgres-backup.yml` (이미지 빌드 워크플로우 폐기 여부 결정)
- Modify: `README.md` (Services 테이블·Backup Strategy 테이블 갱신)

**Step 1: backup.sh 편집**

Run: `grep -n "postgres" backup.sh` → 해당 라인 제거.

**Step 2: Renovate + GHA 이미지 빌드 폐기 여부 결정**

`ghcr.io/ukkiee-dev/postgres-backup` 이미지는 Bitnami 용이었으므로 더 이상 필요 없음:
- `.github/workflows/build-postgres-backup.yml` 비활성화 또는 삭제
- `.github/renovate.json` 의 해당 이미지 규칙 제거

**Step 3: README.md 편집**

- Services 테이블에서 PostgreSQL 행 제거
- Backup Strategy 테이블에서 "PostgreSQL (shared)" 행을 CNPG 계열로 교체
- Tech Stack 에 CNPG + cert-manager + plugin 추가

**Step 4: 커밋 + push**

```bash
git add backup.sh README.md .github/
git commit -m "docs: update backup.sh, renovate, README after Bitnami retirement"
git push origin main
```

## Task 8.6: 최종 검증

**Step 1: Bitnami 흔적 전수 확인**

Run:
```bash
helm list -A | grep -i postgres        # expect: 0 lines (CNPG 는 Helm 아님)
kubectl get all,pvc -A | grep -iE "postgresql(-hl|-metrics)?" | grep -v cnpg   # expect: 0 lines
grep -rn "postgresql-auth\|bitnami.*postgres\|postgresql\.apps" manifests/ argocd/ .github/ --include="*.yaml"  # expect: CNPG 참조 외 0 lines
```

**Step 2: Grafana 패널·알람 정리**

기존 "Bitnami PostgreSQL" 대시보드·알람이 있다면 비활성화 또는 삭제.

**Step 3: Phase 8 완료 기록**

```bash
echo "Phase 8 완료: $(date -Iseconds), Bitnami helm uninstall + ArgoCD cleanup" >> _workspace/cnpg-migration/00_phase-log.md
git commit -am "chore(cnpg): phase 8 bitnami retired (v0.4 helm uninstall path)"
git push origin main
```

---

# Phase 9: 문서화 & 안정화

## Task 9.1: Runbook 5종 작성 (v0.4 리뷰 C2: PITR 분리)

**Files:**
- `docs/runbooks/postgresql/cnpg-new-project.md` — 신규 프로젝트에 DB 추가 (자동·수동)
- `docs/runbooks/postgresql/cnpg-pitr-restore.md` — Phase 4 Task 4.6a 초안 완성 (**동일 namespace 시점복구** · design §8.2 5단계 PR 흐름)
- `docs/runbooks/postgresql/cnpg-dr-new-namespace.md` — Phase 4 Task 4.6b 초안 완성 (**별도 namespace 복구** · DR/감사용)
- `docs/runbooks/postgresql/cnpg-upgrade.md` — operator major + postgres major 업그레이드
- `docs/runbooks/postgresql/cnpg-webhook-deadlock-escape.md` — M3 비상 절차

각각 **증상 → 진단 → 해결 → 검증** 포맷 유지.

**Step 1–4: 파일 작성**

각 Runbook에 실제 Phase 3–6에서 축적된 명령어 · kubectl 출력 · 트러블슈팅 경험을 그대로 기록.

**Step 5: 커밋**

```bash
git add docs/runbooks/postgresql/
git commit -m "docs(runbooks): complete CNPG runbook set (4 files)"
git push origin main
```

## Task 9.2: `docs/disaster-recovery.md` DB 섹션 업데이트

**Files:**
- Modify: `docs/disaster-recovery.md`

**Step 1: DB 손상 시나리오 추가/갱신**

PITR 절차 링크 + RTO/RPO 수치 (PITR 드라이런 Phase 4 측정값 기반).

**Step 2: 커밋**

```bash
git add docs/disaster-recovery.md
git commit -m "docs(dr): add CNPG PITR recovery scenario"
```

## Task 9.3: CLAUDE.md 또는 memory 파일 업데이트

**Files:**
- Modify: `.claude/memory/` 하위 (있다면) 또는 `/Users/ukyi/.claude/projects/-Users-ukyi-homelab/memory/MEMORY.md`

**Step 1: 새 메모리 파일 추가**

`project_cnpg_operational_notes.md` 같은 이름으로:
- namespace-scoped SealedSecret 규약
- Cluster + managed.roles + Database 순서 규약
- webhook deadlock escape 참조
- R2 bucket 구조

**Step 2: MEMORY.md 인덱스 업데이트**

## Task 9.4: 30일 관찰

**Step 1: 관찰 체크리스트**

- [ ] 알람 false positive 건수 (주 1회 점검)
- [ ] 실제 메모리 사용량 vs Phase 0 예측 비교
- [ ] 백업 성공률 100%
- [ ] WAL archive lag 이상 없음
- [ ] operator · plugin · cert-manager restart 횟수

**Step 2: 월간 PITR 드라이런 실행 + Runbook 검증**

Phase 4 절차 그대로 재실행. 소요 시간 측정.

**Step 3: 30일 후 회고 문서**

`docs/plans/2026-05-20-cnpg-migration-postmortem.md` 작성 (postmortem-writer 스킬 활용 가능).

## Task 9.5: Phase 9 완료 + 전체 프로젝트 완료

**Step 1: 성공 기준 체크 (design doc §15)**

- [ ] CNPG 30일 무장애
- [ ] PITR 드라이런 3회 성공
- [ ] setup-app 5분 이내 DB ready
- [ ] 시나리오-1·2 모두 동작
- [ ] 알람 4종 실존 메트릭 · 테스트 발화 성공
- [ ] Bitnami 리소스 0개
- [ ] Runbook 4종 + DR 업데이트
- [ ] 총 메모리 <70% 유지

**Step 2: 최종 로그**

```bash
echo "Phase 9 완료: $(date -Iseconds), 전체 프로젝트 종료" >> _workspace/cnpg-migration/00_phase-log.md
git add _workspace/cnpg-migration/
git commit -m "chore(cnpg): migration complete"
git push origin main
```

---

# Appendix: Task-level TDD 가이드 (Phase 7 자동화 한정)

Phase 7 setup-app composite action의 **yq 병합 로직**은 실수하기 쉬우므로 단위 테스트 권장:

**Files:**
- Create: `.github/actions/setup-app/database/test/`
  - `fixtures/cluster-initial.yaml`
  - `fixtures/cluster-with-one-role.yaml`
  - `fixtures/cluster-with-two-roles.yaml`
  - `fixtures/cluster-with-duplicate-role-input.yaml`  (v0.4 리뷰 M4: 동일 role 이름 2회 추가 입력)
  - `fixtures/cluster-with-duplicate-role-expected.yaml` (expected 출력 = 1개 entry, role 정의 유지)
  - `run.sh` — yq 병합 전/후 비교

**패턴**:

1. **Write the failing test**: 기대 출력 fixture 먼저 작성
2. **Run**: `run.sh` 가 bash-shunit2 또는 단순 diff로 실패 확인
3. **Implement**: composite action의 yq 명령어 작성
4. **Verify**: `run.sh` 성공
5. **Commit**: `feat(setup-app): merge managed.roles idempotently`

각 Phase 7 Task의 yq step마다 위 5-step cycle 적용.

---

# Global Commit Strategy

- Phase마다 최소 3-5개 독립 commit (Task 단위)
- 매 Phase 끝에서 push (remote 반영)
- 중간에 실수 commit이 생기면 revert로 처리 (rebase -i는 ArgoCD GitOps 환경에서 위험)

# Rollback per Phase

| Phase | 단일 명령 |
|---|---|
| 1 | `argocd app delete cert-manager --cascade` |
| 2 | `argocd app delete cnpg-operator cnpg-barman-plugin --cascade` |
| 3 | `kubectl delete ns pg-trial` |
| 4 | `kubectl -n pg-trial delete scheduledbackup,backup --all` + R2 bucket prefix 삭제 |
| 5 | alerts 파일 git revert + argocd sync |
| 6 | 프로젝트 ArgoCD Application 삭제 + namespace 삭제 |
| 7 | `.github/actions/setup-app/database/` 디렉토리 git rm + workflow revert |
| 8 | **되돌리기 어려움** — Phase 6까지 검증 필수 |

---

*End of plan v1.0*
