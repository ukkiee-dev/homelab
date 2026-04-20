# CloudNativePG 마이그레이션 계획 리뷰

> **리뷰일**: 2026-04-20
> **리뷰 대상**:
> - `/Users/ukyi/homelab/docs/plans/2026-04-20-cloudnativepg-migration-design.md` (v0.4, 1622 lines)
> - `/Users/ukyi/homelab/docs/plans/2026-04-20-cloudnativepg-migration-plan.md` (v1.0, 2933 lines)
> - 현재 상태: `/Users/ukyi/homelab/manifests/apps/postgresql/` (4 files, Bitnami 18.5.15 helm drift)
> **리뷰 관점**: 단일 노드 K3s/OrbStack 12Gi · ArgoCD selfHeal · GitOps · 사용자 메모리 누적 함정 13개 반영

---

## 요약 (TL;DR)

**판정: GO with conditions** — 설계 v0.4 는 두 차례 깊은 리뷰를 거치며 사용자가 겪어 온 함정 대부분을 반영했고, 실사용 0개라는 골든 타이밍을 활용하는 전략이 합리적이다. 다만 **착수 전 5건의 블로커성 정합 문제**를 해결해야 plan 의 명령어를 그대로 따라갈 때 첫 PR 단계부터 막힌다.

핵심 근거 5개:

1. **데이터 손실 리스크 0**. Bitnami DB 실사용 앱 0개 (재확인됨, design §1.2). Phase 6 의 첫 실제 프로젝트 전환은 신규 프로젝트 대상 → 마이그레이션 본질이 "이관" 이 아니라 "병행 후 폐기" 이고, 플랜의 단순성·롤백 안정성이 데이터 마이그레이션형 플랜과 비교 불가능하게 좋다.
2. **메모리 풋프린트가 OrbStack 12Gi 안에서 안전**. design §11.2 추정 5 프로젝트까지 ~8Gi (+ 4Gi 헤드룸). 단일 노드 K3s 시스템 오버헤드 2.3Gi 이미 포함.
3. **Plan 과 Design 사이 일관성 누수**. design §D-5 가 옵션 (b) multi-source 권장이라고 명시했는데, plan Task 1.1/2.1/2.5 의 `kustomization.yaml` 은 옵션 (a) `helmCharts` 블록 형태로 작성됨. **둘 중 하나만 살아남아야** 하는데 양쪽이 남아 있어 실행 시 어느 절차를 따를지 모호.
4. **Phase 4 PITR 드라이런이 운영 클러스터를 파괴**. plan Task 4.6 Step 1 은 `pg-trial` (운영 namespace 와 동일) 의 primary 에 `DELETE FROM t` 를 직접 실행. PoC namespace 에서 끝낸 뒤 별도 namespace 에서 복구해야 하는데, 데이터 파괴를 원본 namespace 에 가하면 "복구 가능성" 자체를 검증 못 함 (해당 namespace 의 cluster 가 그대로 살아 있고, restore 결과는 다른 namespace 에서 확인). 의도와 절차 사이 mismatch.
5. **Phase 8 Bitnami 폐기 = 영구**. 한번 helm uninstall 하면 PVC reclaim Delete 로 동시에 PV 사라짐. design §14 도 "돌이키기 어려움" 으로 표시. 사전 조건(30일 안정 + 백업 무결성 검증) 을 신중하게 지키면 안전하지만, plan 의 사전 조건이 Phase 8.0 에서 1줄 체크박스로만 표현되어 운영자 실수 가능성이 있다.

전체적으로 v0.4 가 **사용자의 메모리 13건 중 12건을 명시적으로 반영** (selfHeal/multi-source/AppProject/SSA/large ConfigMap/alert verification/Helm ownership 등). 미반영 1건은 아래 Critical 4 (Helm 메트릭 Service 누락 패턴) — 본 리뷰의 핵심 발견.

---

## Critical 이슈 (블로커)

### C1. Plan 과 Design 사이 D-5 렌더 전략 불일치 — 어떤 길도 절차가 완성되지 않음

- **심각도**: Critical
- **증거**:
  - `design.md:1027` (§12 Phase 0 D-5): "v0.4 권장 (잠정): (b) multi-source"
  - `plan.md:120-124` (Task 0.1): D-5 결정 미확정 체크박스로 남겨둠
  - `plan.md:722-734` (Task 1.1 Step 1): cert-manager `kustomization.yaml` 에 옵션 (a) 형태인 `helmCharts` 블록 코드 예시
  - `plan.md:906-918` (Task 2.1): cnpg-operator `kustomization.yaml` 동일 패턴
  - `plan.md:684-707` (Task 1.0 옵션 b 선택 시): "Task 1.1 의 `kustomization.yaml` → `values.yaml` 만 남기는 형태로 단순화" 라고 적었지만 Task 1.1 자체는 수정 안 함
- **근거**: 옵션 (b) multi-source 를 선택하면 Task 1.1/2.1/2.5 의 `kustomization.yaml` 은 helmCharts 블록 없이 단순 `values.yaml` 만 두는 구조여야 한다. 그런데 실제 Task 1.1 본문은 helmCharts 블록을 그대로 적어 두고 있어, 옵션 (b) 를 선택한 운영자가 plan 을 따라가면 "옵션 (a) 매니페스트" 를 만들어 commit 하게 된다. 메모리 `project_argocd_multisource_deadlock` 도 multi-source 의 위험을 지적 — 잘못 만들면 source 변경 시 kubectl patch 까지 가야 하는 교착에 빠진다. 실제 홈랩 전례 (`argocd/applications/infra/traefik.yaml`) 는 정확히 옵션 (b) 형태이며, sealed-secrets 는 `helm.valuesObject` 인라인. helmCharts 사용 전례는 없다.
- **권장안 (비용-이점)**:
  1. Phase 0 Task 0.1 에서 D-5 를 **(b) multi-source 로 확정** 박제 (이미 권장이므로 결정만 명시).
  2. plan Task 1.1/2.1/2.5 의 `kustomization.yaml` 코드 예시를 multi-source Application 형태로 **전면 재작성**. cert-manager 디렉토리에는 `values.yaml` 한 파일만 두고, ArgoCD Application 에 `sources[0]=helm chart, sources[1]=git ref values` 패턴 (traefik 모범 사례 그대로).
  3. plan Task 1.0 의 옵션 (a)/(b) 분기 블록은 삭제 — D-5 결정 후에는 한 가지 길만 plan 에 남아야 함.
  - **비용**: plan 6개 Task 본문 재작성 1-2시간. **이점**: 첫 PR 부터 절차대로 진행 가능, multi-source 패턴 일관성 유지, helmCharts ↔ argocd-cm 변경의 blast radius 회피.

### C2. Phase 4 Task 4.6 PITR 드라이런이 PoC cluster 의 운영 데이터를 파괴

- **심각도**: Critical
- **증거**: `plan.md:1727-1740` (Task 4.6 Step 1)
  ```bash
  PRIMARY=$(kubectl -n pg-trial get pod ...)  # pg-trial primary
  kubectl exec ... -- psql ... "INSERT INTO t(v) VALUES('pre-restore-marker-...')"
  TARGET_TIME=...
  sleep 90
  kubectl exec ... -- psql ... "DELETE FROM t; INSERT INTO t(v) VALUES('post-destruction');"
  ```
  복구는 `pg-trial-restore` 별도 namespace 에서 수행. 원본 `pg-trial` 의 데이터는 `post-destruction` 상태로 그대로 남는다.
- **근거**:
  - PITR 드라이런의 본질은 "데이터가 파괴된 cluster 를 시점복구" 검증인데, 절차상 데이터 파괴를 원본 cluster 에 가하고 복구는 다른 namespace 에서 검증 → "동일 cluster 가 시점복구 됐는가" 가 검증되지 않음. design §8.2 PITR 절차 (Step 2 원본 Cluster 삭제 후 Step 3 동일 namespace 재선언) 와 plan Task 4.6 의 별도 namespace 접근법이 **본질적으로 다른 시나리오** 를 검증한다.
  - PoC 라 데이터 손실 영향은 실질 0 이지만, 절차가 잘못 박제되면 Phase 9 Runbook (`cnpg-pitr-restore.md`) 도 동일하게 잘못 적힐 위험.
  - design §8.2 의 정확한 절차는 5단계 PR 흐름 (selfHeal off → cluster delete → recovery PR → roles reapply → selfHeal on) 인데, plan Task 4.6 은 "별도 namespace 만들어 새 cluster 세움" 의 단순화 — design 본문 절차의 검증이 아님.
- **권장안 (비용-이점)**:
  1. Task 4.6 을 **두 시나리오로 분리**:
     - 4.6a "동일-namespace 시점복구" (design §8.2 절차 그대로 적용 — selfHeal off PR → cluster delete → bootstrap.recovery PR → 검증). PoC 단계라 ArgoCD 에 등록 안 한 상태이므로 selfHeal PR 부분은 생략하고 kubectl 직접 조작.
     - 4.6b "별도-namespace 새 cluster 복구" (현재 plan 절차) — disaster scenario 시뮬레이션.
  2. `docs/runbooks/postgresql/cnpg-pitr-restore.md` 는 4.6a 기반으로 작성. 4.6b 는 "DR replica 띄우기" 절차로 별도 Runbook 분리.
  - **비용**: plan 1개 Task 분할 2시간 + Runbook skeleton 2개. **이점**: 실제 사고 시나리오 검증 정확도 상승, design §8.2 의 5단계 PR 흐름이 실제로 동작하는지 사전 검증.

### C3. CNPG operator 가 메트릭 Service 를 자동 생성하지 않을 가능성 (Helm metrics Service 누락 패턴)

- **심각도**: Critical
- **증거**:
  - 메모리 `project_argocd_metrics_service_gap`: "ArgoCD Helm metrics Service 누락 — controller/server/repoServer.metrics.enabled=true 만으론 Service 안 생김, Kustomize 로 별도 추가"
  - design `§D16` / plan Task 5.1: "CNPG pod `/metrics` 9187 포트를 Alloy `kubernetes_sd_configs` 로 직접 scrape (PodMonitor CRD 미사용)"
  - plan Task 2.1 Step 2 values.yaml 예시: `monitoring.podMonitorEnabled: false` + Alloy 직접 scrape 전제
- **근거**: CNPG operator chart 의 metrics 노출은 `monitoring.podMonitor.create` (혹은 유사 키) 가 PodMonitor + Service 를 함께 만드는 형태가 일반적. PodMonitor 만 끄고 Alloy 가 pod 직접 scrape 하면 동작은 하지만, **operator 자체 메트릭** (cnpg-system pod, 포트 8080) 의 Service 도 자동 생성되지 않을 위험. design §10.1 은 "operator 자체 메트릭 (cnpg-system namespace · 포트 8080)" scrape 를 언급하지만 plan Task 5.1 은 cluster pod (9187) 만 다룬다.
  - 메모리 ArgoCD 사례와 동일한 패턴이 CNPG operator chart 에서 재현될 수 있음 — chart values 가 enabled=true 인데 Service 는 생성 안 되는 경우.
  - Plan Task 0.2 Step 3 의 `helm show values` 덤프가 이 문제를 잡을 수 있는 유일한 게이트.
- **권장안 (비용-이점)**:
  1. Phase 0 Task 0.2 Step 3 에 **operator 메트릭 노출 키 검증** 명시: `yq '.monitoring' _workspace/cnpg-migration/08_cnpg-chart-values.yaml` 출력에 `serviceMonitor` / `podMonitor` / `service` 모든 키 점검 + 어떤 키가 Service 를 생성하는지 chart README 와 교차확인.
  2. 만약 chart 가 Service 생성을 지원하지 않으면 **Phase 5 Task 5.1.1 신규**: `manifests/infra/cnpg-operator/metrics-service.yaml` 를 Kustomize patches 로 추가 (메모리 ArgoCD 사례 그대로 적용).
  3. plan Task 5.2 Step 3 의 메트릭 검증을 cluster pod 메트릭뿐 아니라 operator pod 메트릭 (포트 8080) 까지 확장.
  - **비용**: Phase 0 Step 3 추가 5분 + Phase 5 신규 Task 30분-1시간. **이점**: 최근 ArgoCD 와 동일한 함정 회피, design §10.1 약속 (operator 메트릭) 실제 이행.

### C4. Phase 4 Task 4.5 ScheduledBackup 의 `backupOwnerReference: self` — design §D5 H5 결정과 충돌

- **심각도**: Critical (낮은 발생빈도지만 audit trail 손실 영구)
- **증거**:
  - `design.md:281-294` (§D3 D5 H5 반영): `backupOwnerReference: cluster` 채택, "v0.3 'self' → v0.4 'cluster' 로 전환" 명시
  - `design.md:349`: `backupOwnerReference: cluster` 다시 강조
  - `plan.md:1700`: ScheduledBackup YAML 에 `backupOwnerReference: self`
  - `design.md:1477` (§Appendix A.7): `backupOwnerReference: cluster`
- **근거**: design 본문과 Appendix 는 모두 `cluster` 인데 plan 의 실제 매니페스트 코드는 `self` — v0.3 잔재가 plan 에서 미반영. 이대로 적용하면 운영자가 ScheduledBackup spec 을 수정·재생성하는 순간 모든 Backup CR 이 cascade 삭제되어 audit trail 이 영구 손실된다 (R2 객체 자체는 retentionPolicy 로 별도 관리되지만, "언제 어떤 백업이 있었나" 의 K8s API 기록 0건).
- **권장안 (비용-이점)**:
  1. plan Task 4.5 Step 1 ScheduledBackup YAML 에서 `backupOwnerReference: self` → `cluster` 1줄 수정.
  2. plan 전역에서 `grep -n "backupOwnerReference" plan.md` 로 추가 잔재 확인.
  3. plan Task 6.2/7.3 의 ScheduledBackup 템플릿 (.tpl) 도 동일 적용.
  - **비용**: 1줄 수정 5분. **이점**: design 결정과 plan 일치, 운영자 실수 방지.

### C5. cert-manager values.yaml 의 `installCRDs` 키 — chart v1.15+ 에서 deprecated, `crds.enabled` 로 변경

- **심각도**: Critical
- **증거**: `plan.md:739` (Task 1.1 Step 2): `installCRDs: true` · `design.md:1341` 동일
- **근거**: cert-manager Helm chart v1.15.0 (2024-06) 부터 `installCRDs` 는 deprecated, `crds.enabled` + `crds.keep` 로 분리. v1.16+ 일부 버전에서는 silently ignored. Phase 0 I-2 에서 최신 stable (현재 v1.18.x) 을 pin 하면 `installCRDs: true` 가 무시되어 CRD 미설치 → ClusterIssuer/Certificate 만들기 시점에 "no matches for kind" 에러 → Phase 1.4 검증 (Task 1.4 Step 3) 에서 `kubectl get crd | grep cert-manager` 가 0건으로 발견되지만, 그 시점에 이미 ArgoCD Application 이 syncWave -3 으로 reconcile 시도 중이라 디버깅 시간 소모.
- **권장안 (비용-이점)**:
  1. plan Task 1.1 Step 2 values.yaml 을 다음으로 교체:
     ```yaml
     crds:
       enabled: true
       keep: true   # uninstall 시 CRD 잔존 (PV 유사 안전장치)
     ```
  2. design §A.1 도 동일 수정.
  3. Phase 0 Task 0.2 Step 3 의 cert-manager values 스키마 덤프에서 `crds.enabled` 키 존재 확인 절차 추가.
  - **비용**: 2줄 수정 + 검증 1분. **이점**: Phase 1 첫 sync 에서 CRD 누락 디버깅 시간 절감 (예상 30분-1시간), `crds.keep: true` 로 향후 chart uninstall 사고 방지.

---

## High 이슈 (배포 전 해결 필요)

### H1. Phase 6 의 ArgoCD Application 등록 시점에 `apps` AppProject 의 cluster resource whitelist 부족

- **심각도**: High
- **증거**:
  - `plan.md:2210-2211` (Task 6.3 Step 2): "apps AppProject clusterResourceWhitelist는 postgresql.cnpg.io/* namespace-scoped이므로 보통 문제 없음 (검증)"
  - `manifests/infra/argocd/appproject-infra.yaml`: 현재 `apps` project 의 whitelist 미확인
  - `appproject-apps.yaml` 도 별도 점검 필요
- **근거**: design §D11 은 **infra** AppProject 3축 확장만 다루고, **apps** AppProject 가 CNPG CR (Cluster, Database, ScheduledBackup, ObjectStore, Backup) 을 namespace-scoped 로 다룰 때 자동 통과한다고 가정. 그러나:
  - ObjectStore CR (`barmancloud.cnpg.io/v1`) 가 namespace-scoped 인지 cluster-scoped 인지 plan 에서 검증 누락 (Phase 0 I-2a 의 Database CRD stability 검증과 같은 수준의 검증 없음).
  - apps AppProject 가 `namespaceResourceWhitelist` 를 화이트리스트 모드 (특정 group 만 허용) 로 운영 중이라면 `postgresql.cnpg.io/*`, `barmancloud.cnpg.io/*` 미등록 시 sync 실패.
  - 메모리 `project_argocd_appproject_cluster_resources` 의 교훈은 "리소스 추가 시 먼저 whitelist 업데이트" — namespace-scoped 도 동일 적용.
- **권장안**:
  1. Phase 0 Task 0.7 (AppProject diff) 에 **apps AppProject 도 점검 대상 추가**. 현재 `namespaceResourceWhitelist` 가 있으면 CNPG/barman group 추가, 없으면 (모든 namespace 리소스 허용 모드) 그대로 두기.
  2. Phase 2.0 (design §D11) 에서 apps AppProject 도 동시 PR.
  - **비용**: Phase 0 Task 0.7 확장 30분. **이점**: Phase 6 첫 실제 프로젝트 sync 에서 `Resource ... is not permitted in project apps` 에러 회피.

### H2. ARC runner 가 in-cluster 에서 kubeseal Service 호출하려면 RBAC + NetworkPolicy 가 필요한데 미검증

- **심각도**: High
- **증거**:
  - `design.md:521`: "ARC runner 는 `actions-runner-system` 네임스페이스에 in-cluster 배포되어 있음. kubeseal 은 `--controller-namespace sealed-secrets --controller-name sealed-secrets-controller` 플래그로 Service 를 직접 호출"
  - `plan.md:355-372` (Task 0.8): kubeseal `--fetch-cert` 만 검증, 실제 seal (Secret 데이터를 controller 에 보내고 ciphertext 받기) 은 미검증
  - 메모리 `feedback_argocd_changes` 정신: "변경 후 동작 검증 필수"
- **근거**: kubeseal `--fetch-cert` 는 controller 의 public key 만 가져오는 read-only RBAC. 실제 seal 은 클라이언트 사이드에서 cert 로 암호화하므로 RBAC 추가 필요 없음 — 이 부분은 OK. 그러나:
  - **NetworkPolicy**: `actions-runner-system` → `sealed-secrets` (kube-system) namespace 간 egress 가 default-deny 환경에서 막힐 수 있음. design §9 는 `apps` namespace 의 NetworkPolicy 만 다루고, ARC runner 의 egress 통제 상태 미점검.
  - **실제 seal 동작 시점**: Phase 7 Task 7.4 (composite action) 에서 처음 시도. Phase 0 에서 미리 검증 안 하면 Phase 7 자동화 작성 후 실패 시 원인 분리 어려움.
- **권장안**:
  1. Phase 0 Task 0.8 Step 1 에 **실제 seal 까지 e2e 테스트 추가**:
     ```bash
     echo "test-secret-value" | kubectl create secret generic test-seal --dry-run=client \
       --from-literal=key=- -o yaml | \
     kubeseal --controller-namespace sealed-secrets \
              --controller-name sealed-secrets-controller \
              --format=yaml > /tmp/test-sealed.yaml
     test -s /tmp/test-sealed.yaml && grep -q "encryptedData:" /tmp/test-sealed.yaml \
       && echo "OK" || echo "FAIL"
     ```
  2. ARC runner pod 에서 `kubectl exec` 로 동일 명령 재실행 → in-cluster 경로 검증.
  3. NetworkPolicy egress 확인 (`actions-runner-system` namespace 의 NP 점검).
  - **비용**: Phase 0 Task 0.8 확장 20분. **이점**: Phase 7 자동화 디버깅 시 "이건 Phase 0 에서 통과했음" 으로 원인 범위 축소.

### H3. Phase 0 R2 Object Lock 조사 (I-7) 결과가 design.md §8.4 에는 박제되어 있는데 plan 에는 그 결과를 어떻게 적용할지 후속 Task 누락

- **심각도**: High
- **증거**:
  - `design.md:891-906` (§8.4 I-7 결과): R2 Bucket Locks (prefix=wal, Age=21d) Terraform 으로 선언 + R2 lifecycle (base/ prefix 14d) 권장 + Phase 4 E2E POC 명시
  - `plan.md` 에서 Phase 4 (`Task 4.1-4.8`): Bucket Lock + lifecycle Terraform 선언 Task 0건. 단순히 R2 bucket 만들고 ObjectStore CR 만 적용.
  - `plan.md:564-599` (Task 0.11c I-7): "조사 결과 박제" 만 함, 실제 Bucket Lock 적용 Task 부재
- **근거**: R2 single source 리스크 완화 (R14) 의 핵심 조치인 Bucket Lock 이 plan 에 액션 아이템으로 떨어지지 않음. Terraform IaC 가 이미 도입되어 있는데도 (메모리 `project_cloudflare_v5_migration` 참조) cloudflare provider v5.4+ 의 `cloudflare_r2_bucket_lock` 리소스 적용 절차가 plan 에 없음. Phase 4 POC (Bucket Lock vs Barman backup-delete 호환성) 도 Task 로 분해 안 됨.
- **권장안**:
  1. Phase 0 Task 0.5 Step 5 신규: Cloudflare provider 버전 확인 (`>= 5.4.0` 필요) + `terraform/r2-pg-backups.tf` 작성 (bucket + lock rule + lifecycle).
  2. Phase 4 Task 4.4.5 신규: "Bucket Lock 활성 상태에서 on-demand Backup → barman-cloud `backup-delete` 호환성 POC". 호환 안 되면 plan 에 fallback 결정 (Lock 비활성 + lifecycle 만, 또는 plugin upstream 이슈 보고) 분기.
  3. 호환 실패 시 R14 완화 수단이 R2 lifecycle 단독으로 약화되므로 §16 후속 (외장 SSD mirror) 우선순위 상향 검토.
  - **비용**: Phase 0 Task 추가 1시간 + Phase 4 POC 2시간. **이점**: ransomware/계정 탈취 시 21일 WAL 보호선 확보, design §8.4 약속 이행.

### H4. Phase 5 알람 검증 (Task 5.5) 의 "임시 rule 추가" 절차가 운영 Grafana state 에 영구 흔적 가능

- **심각도**: High
- **증거**:
  - `plan.md:2086-2105` (Task 5.5): Grafana UI 에서 임시 rule 추가 → 5분 내 Telegram 도착 확인 → 즉시 삭제
  - 메모리 `feedback_alert_metric_verification`: "알람 YAML ≠ 동작 검증 필수" — 정신은 정확하나 실행 절차의 부작용
  - 메모리 `feedback_alert_startup_burst`: `process_start_time_seconds` grace period 필수
- **근거**:
  - Grafana alerting state history 는 임시 rule 의 발화·해제 이벤트를 영구 기록. test=true 라벨로 필터링 가능하지만 운영 대시보드의 "최근 알람" 패널에 노출 가능.
  - UI 로 추가한 rule 은 Git 매니페스트에 없어 selfHeal/sync 와 무관하게 살아 있음 → 운영자가 잊고 안 지우면 영구 false positive 알람.
  - 더 큰 문제: design §10.4 (M4) 는 "alertmanager silence 로 라우팅만 검증" 옵션을 제시했는데, plan 은 안전한 옵션 (silence) 대신 위험한 옵션 (UI rule 추가) 을 채택.
- **권장안**:
  1. plan Task 5.5 절차를 **silence 기반 검증** 으로 교체: 
     - 기존 rule 의 임계값을 `cnpg_collector_up == 1` 같은 즉시 발화 식으로 일시 변경 (Git PR) → 발화 확인 → 원본 expr 로 revert PR.
     - 또는 alertmanager amtool 로 강제 발화 시뮬레이션.
  2. 어느 방식이든 **재현 가능한 git diff** 형태로 절차 박제 (UI 클릭 절차 제거).
  3. Task 5.5 Step 4 신규: `kubectl logs -n monitoring deploy/grafana | grep CNPGTestFire` 로 발화 로그 직접 확인 후 라우팅 1단계만 검증 (Telegram 도착은 spot-check).
  - **비용**: 절차 재작성 30분. **이점**: state history 오염 방지, GitOps 일관성 유지, "잊고 안 지운 rule" 사고 회피.

### H5. ScheduledBackup `interval: 1m` 알람 evaluation 과 PVC 메트릭 라벨 매칭 정확도

- **심각도**: High
- **증거**:
  - `plan.md:2048-2056` (Task 5.4): `kubelet_volume_stats_used_bytes{persistentvolumeclaim=~".*-pg-.*"}` 정규식 매칭
- **근거**:
  - CNPG 가 만드는 PVC 이름 패턴은 `<cluster-name>-1`, `<cluster-name>-2` (instance 번호 suffix) — `-pg-` 가 cluster 이름에 들어가야 매칭. Plan 의 default cluster 이름이 `<project>-pg` 이므로 PVC 이름은 `<project>-pg-1` → 정규식은 매칭됨.
  - 그러나 WAL PVC 가 별도로 생성될 경우 (design 은 통합 5Gi 로 결정했지만 Cluster spec.walStorage 가 향후 추가될 가능성) `<cluster>-wal-1` 패턴 — 정규식 미매칭.
  - 더 안전한 방법은 CNPG 가 PVC 에 자동으로 붙이는 라벨 `cnpg.io/cluster=<cluster>` 매칭.
- **권장안**:
  1. plan Task 5.4 알람 expr 변경:
     ```promql
     kubelet_volume_stats_used_bytes{namespace=~".+", persistentvolumeclaim=~".+"} 
       / on (namespace, persistentvolumeclaim) 
       kubelet_volume_stats_capacity_bytes{namespace=~".+", persistentvolumeclaim=~".+"} > 0.8
       and on (namespace, persistentvolumeclaim) 
       group_left() label_replace(
         kube_persistentvolumeclaim_labels{label_cnpg_io_cluster=~".+"}, 
         "persistentvolumeclaim", "$1", "persistentvolumeclaim", "(.+)")
     ```
     또는 단순히 `kube_persistentvolumeclaim_labels{label_cnpg_io_cluster!=""}` 결합. (kube-state-metrics 도입 전제 — 미도입이면 plan 에 추가)
  2. Phase 0 I-1 (실제 메트릭 dump) 에서 PVC 이름 패턴 확인 후 정규식 최종 결정.
  - **비용**: PromQL 재작성 1시간. **이점**: 향후 walStorage 분리 도입 시 알람 자동 커버, false negative 방지.

### H6. Phase 8 데이터 손실 영구화 직전 단계의 Go/No-Go 게이트 부재

- **심각도**: High
- **증거**:
  - `plan.md:2570-2585` (Task 8.0): "CNPG 30일 안정 운영 확인" + "I-0a 결정 재확인" 2개 체크박스
  - `plan.md:2666-2697` (Task 8.3-8.4): helm uninstall + PVC delete (PV reclaim Delete → PV 영구 삭제)
- **근거**:
  - design §14 가 Phase 8 을 "돌이키기 어려움" 으로 표시했지만, plan 의 사전조건 절차는 30일 운영 + 결정 재확인 2줄로 매우 가벼움.
  - 메모리 `feedback_argocd_changes` 의 정신은 "변경 전 검증" 인데, Phase 8 은 변경 후 복구 자체가 불가능한 단계 — 사전 검증 강도가 다른 Phase 의 5배 이상이어야 함.
  - PVC reclaim policy 가 Delete 면 helm uninstall → PVC delete → PV delete → 호스트 디렉토리 (local-path) 삭제 → 데이터 영구 손실. Bitnami StatefulSet 데이터는 실사용 0이라 영향 없지만, 운영자 실수로 잘못된 PVC 를 지울 위험.
- **권장안**:
  1. Phase 8.0 사전 조건 체크리스트 확장:
     - [ ] 마지막 백업 무결성 검증 통과 (Task 8.2 Step 4 결과 박제)
     - [ ] R2 archive prefix 에 dump 파일 SHA256 + 파일 크기 기록 (`rclone hashsum SHA256`)
     - [ ] 외장 SSD `/Volumes/ukkiee/.../monthly/` 에 dump 1부 추가 보관 (R2 의존성 제거)
     - [ ] `data-postgresql-0` PV 의 hostPath 경로를 운영자가 ssh 직접 확인 + `du -sh` 기록
     - [ ] 운영자 self-review: "이 PVC 의 데이터가 정말 사용 0건인가" 를 `pg_stat_user_tables` 출력 박제로 확인
     - [ ] CNPG 측 30일 안정 운영을 알람 false positive 0 + 백업 성공 30/30 + PVC 사용률 안정 그래프 스크린샷
  2. Task 8.3 Step 2 의 `helm uninstall` 직전 5초 sleep + 운영자 명시적 confirmation prompt:
     ```bash
     read -p "Bitnami PostgreSQL 영구 삭제. data-postgresql-0 (5Gi, hostPath ...) 데이터 손실됨. 계속 진행? (yes/no): " ans
     [ "$ans" = "yes" ] || { echo "abort"; exit 1; }
     ```
  3. Phase 8.4 PVC delete 전 PV 의 reclaim policy 를 일시적으로 Retain 으로 patch → PVC 삭제 후 PV 만 남음 → 30일 후 수동 PV 삭제 (안전 마진).
  - **비용**: Phase 8.0 체크리스트 확장 30분 + Task 변경 1시간. **이점**: 영구 데이터 손실 사고 방지.

---

## Medium 이슈 (배포 후 개선 또는 모니터링 필요)

### M1. `primaryUpdateStrategy: unsupervised` 가 단일 인스턴스에서 minor 업그레이드 시 다운타임 발생

- **심각도**: Medium
- **증거**: `design.md:233` `plan.md:1303` 모두 `primaryUpdateStrategy: unsupervised` + design §D3 H6 Renovate 정책으로 완화
- **근거**: instances=1 단일 인스턴스에서 unsupervised 는 사실상 "minor 업그레이드 = 즉시 재시작 = 다운타임". Renovate auto-merge 금지 + dashboard approval 로 트리거 시점은 통제하지만, 트리거 후 10초~1분 다운타임은 그대로. CNPG `inplace` 업그레이드 메서드를 명시하면 빠르게 끝나고, `restart` 메서드는 더 안전하지만 느림. plan 에 업그레이드 메서드 선택 부재.
- **권장안**: design §D3 에 업그레이드 메서드 (`inplaceUpdates: true` vs default rolling) 명시 + 다운타임 SLO 박제 (예상 30초-2분). Phase 9 Runbook `cnpg-upgrade.md` 에 다운타임 윈도우 운영자 사전 공지 절차 추가.
- **비용-이점**: 1줄 spec + Runbook 30분 / 운영자 다운타임 예측 가능.

### M2. Phase 5 Alloy scrape config 가 River 문법 + Prometheus YAML 두 가지 fallback — 실제 사용 중인 형식 미확정

- **심각도**: Medium
- **증거**: `plan.md:1878-1928` (Task 5.1 Step 2): River + YAML 둘 다 제시, "실제 River 문법은 기존 파일 기준으로 맞춤" 단서.
- **근거**: 운영자가 plan 을 기계적으로 따르면 두 가지 형식 중 무엇을 쓸지 결정 못 함. Phase 0 Task 0.4 (baseline 실측) 에서 Alloy config 형식을 미리 박제하면 좋음.
- **권장안**: Phase 0 Task 0.4 Step 4 신규: "Alloy config 파일 형식 (River vs Prometheus YAML) + 기존 scrape job 중 하나를 사례로 박제" → Phase 5 Task 5.1 코드 예시를 단일 형식으로 좁힘.

### M3. ObjectStore CR 의 `endpointURL` 에 `<ACCOUNT_ID>` placeholder — Phase 0 Task 0.9 치환 스크립트와 키 이름 불일치

- **심각도**: Medium
- **증거**: 
  - `plan.md:1578`: `endpointURL: https://<ACCOUNT_ID>.r2.cloudflarestorage.com`
  - `plan.md:391`: `export R2_ACCOUNT_ID_PUBLIC="<...>"`
  - `plan.md:407`: `sed -i ... -e "s|<ACCOUNT_ID>|${R2_ACCOUNT_ID_PUBLIC}|g"`
- **근거**: 치환은 작동하지만 변수명 (`R2_ACCOUNT_ID_PUBLIC`) 과 placeholder (`ACCOUNT_ID`) 가 일관성 없어 운영자 혼란. Task 0.5 의 `02_r2-credentials.txt` 는 `R2_ACCOUNT_ID` (PUBLIC suffix 없음) — 또 다른 변수명. 3개 이름 통일 필요.
- **권장안**: 모두 `R2_ACCOUNT_ID` 로 통일.

### M4. Phase 7 Task 7.4 composite action 의 yq managed.roles 병합 — idempotency 미검증

- **심각도**: Medium
- **증거**: `plan.md:801` `yq eval -i '.spec.managed.roles += [...]'` (배열 append) — 동일 role 두 번 setup-app 호출 시 중복 추가
- **근거**: GHA workflow 가 재실행될 가능성 (실패 후 retry) + 같은 role 이름 중복 시 CNPG 가 거부. plan Appendix TDD 가이드는 fixture 기반 테스트 권장하지만 구체적 idempotency 케이스 부재.
- **권장안**: yq 명령을 idempotent 하게:
  ```yaml
  # 기존 role 제거 후 추가 (혹은 select 로 존재 확인)
  yq eval '.spec.managed.roles = (.spec.managed.roles + [...] | unique_by(.name))' -i ...
  ```
  Appendix TDD fixture 에 "동일 role 두 번 추가" 케이스 명시.

### M5. ARC runner 가 ghcr 외부 트래픽 + sealed-secrets in-cluster 동시 호출 시 NetworkPolicy 영향

- **심각도**: Medium
- **증거**: design §9 NetworkPolicy 는 `apps` namespace 만 다룸. `actions-runner-system` 의 NP 미점검.
- **근거**: 메모리 `project_argocd_appproject_cluster_resources` 의 정신을 보안에도 적용하면, ARC runner namespace 의 default-deny 가 있으면 sealed-secrets 호출 차단 가능. Phase 0 Task 0.8 에서 검증해도 NP 가 나중에 추가될 수 있음 → Phase 7 자동화 시점에 회귀.
- **권장안**: Phase 7 시작 시 ARC runner namespace 의 NP 상태 박제. Phase 9 Runbook 에 "ARC runner → sealed-secrets-controller 통신" 다이어그램.

### M6. R2 backup 의 ScheduledBackup 한 개만 — base/incremental 구분 없음

- **심각도**: Medium
- **증거**: `plan.md:1689-1700` ScheduledBackup 1개 (daily UTC 18:00 = KST 03:00)
- **근거**: barman-cloud plugin 이 incremental backup 을 지원하나 plan 에 활용 없음. 매일 full base + 24h WAL = R2 에 매일 풀백업 1개. 5GB DB 면 1년 1.8TB. retention 14일이면 70GB. 비용은 적지만 R2 egress 시간 (Phase 8.6 의 R2 archive prefix 정리 등) 누적.
- **권장안**: §16 (out of scope) 에 "incremental backup 정책 도입" 추가. design §D5 의 backup 방법 옵션 (`full | incremental`) 을 plan Task 4.5 ScheduledBackup spec 에 명시 (현재 default = full).

### M7. Phase 6 Task 6.4 Step 5 의 psql verify 가 sslmode=require 인데 cluster 가 verify-full 거부 시 정확한 에러 진단 부재

- **심각도**: Medium
- **증거**: `plan.md:2259` `psql "postgresql://${ROLE}@${CLUSTER}-rw:5432/${DB}?sslmode=require"`
- **근거**: design §D13 은 `sslmode=require` 기본 + CA 미마운트. cluster 가 self-signed 면 require 통과. 그러나 cluster 가 cert-manager Issuer 의 cert 받았을 때 SNI 미설정으로 hostname mismatch 가능성. 운영 시 디버깅 어려움.
- **권장안**: Phase 6 Task 6.4 Step 5 에 sslmode=disable 부터 시작해서 require 까지 단계별 검증 (디버깅 친화).

### M8. Plan Task 5.4 알람 expr `cnpg_collector_pg_wal_archive_status{value="ready"} > 10` — gauge metric 의 라벨 의미 검증 없음

- **심각도**: Medium
- **증거**: `plan.md:2040` 메트릭 이름과 라벨 키 추정
- **근거**: Task 3.8 메트릭 dump 에서 `cnpg_collector_pg_wal_archive_status` 가 실존 여부 + 라벨 키가 `value` 인지 `state` 인지 unknown. plan Task 3.8 Step 2 가 메트릭 이름은 검증하지만 라벨 키 미검증.
- **권장안**: Task 3.8 Step 2 에 라벨 키 dump 추가:
  ```bash
  curl -s ...:9187/metrics | grep "^cnpg_collector_pg_wal_archive_status" | head
  ```
  실제 출력 박제 후 알람 expr 작성.

### M9. setup-app 자동화의 `database.storage` override — local-path 5Gi 기본의 의미가 setup-app 시점에 고정

- **심각도**: Medium
- **증거**: `plan.md:2421` (Task 7.4): `storage: { required: false, default: "5Gi" }`
- **근거**: local-path resize 미지원 (D 시나리오) → setup-app 시점에 storage 결정 후 변경 불가. 운영자가 처음에 5Gi 설정하고 나중에 부족하면 backup → bootstrap.recovery 에 endpoint swap (design §11.3 Runbook 예정) 거쳐야 함. 매우 큰 운영 부담. **OpenEBS LocalPV Hostpath 전환 (followup TODO) 까지 이 부담 지속**.
- **권장안**: setup-app 의 default 를 `10Gi` 로 더 보수적으로 상향 (R2 비용은 retention 14d 기준 미세). app owner 가 명시적으로 줄일 수 있게.

### M10. Plan Task 1.4 Step 4 의 Traefik ACME 회귀 점검 명령이 placeholder

- **심각도**: Medium
- **증거**: `plan.md:883`: `kubectl -n <traefik-ns> logs deploy/traefik | grep -i acme | tail -20`
- **근거**: `<traefik-ns>` 는 실제 `traefik-system` 으로 치환 가능. 그러나 plan 에 placeholder 그대로 남아 있어 운영자가 mistype 가능. Phase 0 Task 0.9 의 sed 치환 대상에 누락.
- **권장안**: plan 전역 grep 으로 `<` 시작 placeholder 모두 표준화 + 치환 스크립트 cover.

### M11. design §D14 에서 Cloudflare IP range egress allow 를 "후속 개선" 으로 분리 — Phase 5 NetworkPolicy 작성 시 사실상 미적용

- **심각도**: Medium
- **증거**: `design.md:594-605` (§D14), plan 에 NetworkPolicy 추가 Task 부재
- **근거**: design §9 표는 "egress: kube-dns + Cloudflare CIDR + 443" 명시했지만 plan 의 어느 Phase 에서도 NP 매니페스트 생성 Task 없음. Phase 6 Task 6.2 의 common/ 8 파일 목록에 NP 누락. R2 백업 동작은 NP 부재 시 통과 (default-allow), 하지만 design 의 보안 약속 미이행.
- **권장안**: Phase 6 Task 6.2 에 `common/network-policy.yaml` 추가 (cluster pod ingress: 같은 namespace + monitoring · egress: kube-dns + 443/TCP 전부 허용 또는 Cloudflare CIDR). Phase 7 템플릿에도 NP 포함.

---

## Low / Info (참고)

### L1. Plan total 12-15일 — 단일 운영자 풀타임 기준은 비현실적

- 단일 운영자 파트타임 (homelab) 기준 실제 소요는 3-4주 예상. plan 에 "calendar week" vs "engineering day" 구분 표기 권장.

### L2. Phase 0 Task 0.0 가 pre-verified 상태로 완료 표시되어 있어 Phase 0 가 시작 시점 부담을 약간 덜어줌 — 좋은 패턴

### L3. Phase 9 Task 9.4 의 30일 관찰이 사실상 "Phase 8 polepoletes 완료 후 30일 wait" 라서 마이그레이션 종료가 Phase 9 끝 + 30일 → 총 calendar 60-75일

### L4. Out-of-scope §16 항목 11개 — 적절한 YAGNI 억제. 외장 SSD mirror 만 R14 완화 후속으로 우선순위 높음.

### L5. Plan TDD 가이드 (Appendix) 가 Phase 7 yq 만 다룸 — Phase 1-6 의 ArgoCD/CNPG 동작 자체는 통합 테스트 부재. 의도적 (operator/chart 가 upstream 책임) — OK.

### L6. design §D9 `.app-config.yml` 의 `mode: reference` semantic 이 "동일 계정 공유" 임을 명확히 박제한 점 (v0.4 H1) — 향후 운영자 혼란 예방. 매우 좋음.

### L7. Phase 0 R2 credential 보관 (`02_r2-credentials.txt`) 이 평문 — gitignore 에 추가하지만 macOS 디스크 암호화 미설정 시 노출. 작은 리스크.

### L8. plan 에 "Phase 5 이후 일부 parallel 가능" 표기 (Index) 인데 실제 의존성 그래프 없음. Phase 6 ↔ Phase 7 병행 가능 여부 불명.

---

## 보완 권고 (계획 자체의 품질 향상)

### P1. Phase 별 "롤백 한계 시점" 명시 표

각 Phase 가 끝나기 전 vs 끝난 후 롤백 비용을 Phase 별로 표시. 예:
| Phase | 진입 전 rollback | 진행 중 rollback | 완료 후 rollback |
|---|---|---|---|
| 1 | 무비용 | Application 삭제 + CRD 수동 제거 (5분) | 동일 |
| 2 | 무비용 | 동일 | CRD 8종 의존 리소스 발생 후 cascade 위험 |
| 8 | 가능 | **불가 (helm uninstall 진행 중)** | **불가 영구** |

### P2. Phase 4 PITR 드라이런이 Phase 9 Runbook 의 데이터 소스 — Runbook 작성을 Phase 4 직후 강제

design §12 Phase 9 의 L8 반영 ("Phase 3·5·8 직후 skeleton commit") 가 plan 에서는 Phase 4 Task 4.7 로 부분 반영. Phase 9 Task 9.1 도 Phase 4 의 출력 직접 참조하도록 명시.

### P3. 사용자 메모리 13개 중 미반영 1개 = `project_argocd_metrics_service_gap` (위 C3 으로 격상)

design Appendix B (메모리 체크리스트) 에 8개만 체크. metrics service gap, traefik gomemlimit SSA, multi-source deadlock, AdGuard Tailscale DNS, Cloudflare v5 migration, Postgres GUC pin (M3 부분만), large ConfigMap SSA — 명시적 체크 누락 5개. design Appendix B 갱신 권장.

### P4. Phase 0 결정·조사 결과 박제 파일 13개 (`_workspace/cnpg-migration/00-16_*.md`) — Index 부재

plan 끝부분 Appendix 에 박제 파일 인덱스 표 추가. Phase 별로 어떤 박제가 산출물인지 시각화.

### P5. 백업 검증 자동화 — design §16 후속 인데 Phase 9 안정화 단계에 우선 도입 검토

`dr-verification` 스킬 활용 + R2 dump 의 `pg_restore --list` 자동 검증 CronJob (월 1회). Phase 8 의 Bitnami 폐기 직전 검증 (Task 8.2 Step 4) 과 동일 절차를 CronJob 화 → 운영 안정성 즉시 향상.

### P6. ResourceQuota / LimitRange 적용 (단일 노드 환경)

`appproject-infra.yaml` 의 destinations 주석을 보면 scheduling application 이 ResourceQuota 를 각 namespace 에 배포한다. CNPG 도입한 신규 namespace (pg-trial, pg-demo, 첫 실제 프로젝트) 에 ResourceQuota 자동 적용 보장 절차 plan 부재. 메모리 `project_k3s_system_memory` (12Gi 한계) 고려 시 명시 필요.

### P7. ArgoCD Application 의 `ignoreDifferences` 누락 — CNPG operator 가 Cluster CR 에 status·이벤트 외 spec 자동 변경 가능

traefik 의 GOMEMLIMIT SSA 충돌 (메모리 `project_traefik_helm_v39_gomemlimit_ssa`) 같은 패턴이 CNPG 에서도 발생 가능. 특히:
- `Cluster.spec.bootstrap.initdb.encoding` 같은 default 값 자동 채움
- `managed.roles[].password` 회전 시 spec 변경
- `monitoring.disableDefaultQueries` default 추가

→ Phase 6 ArgoCD Application 매니페스트 (Task 6.3) 에 사전 `ignoreDifferences` 블록 + Phase 9 Runbook 에 "drift 발생 시 추가 절차" 박제 권장.

---

## 롤백 시나리오 검증

| Phase | 롤백 절차 (plan) | 실제 동작 평가 |
|---|---|---|
| 0 | 문서·조사만 | OK — 무위험 |
| 1 (cert-manager) | `argocd app delete cert-manager --cascade` | **부분 OK** — CRD 가 Helm 의 `crds.keep: true` 면 잔존. Plan 에 명시 권장 (위 C5 참조) |
| 2 (operator + plugin) | Application 2개 삭제 | **부분 OK** — Cluster CR 이 어딘가에 살아 있으면 cascade 도중 finalizer block 가능. Phase 2 단계에서는 CR 0건이므로 안전. design §M3 (operator scale 0 escape) 미적용 |
| 3 (PoC) | `kubectl delete ns pg-trial` | OK — 단 PVC 가 Retain 인지 Delete 인지 검증 필요 (local-path default Delete) |
| 4 (backup) | ScheduledBackup·Backup 삭제 + R2 prefix 비우기 | **위험** — `backupOwnerReference: self` 였다면 ScheduledBackup 삭제 = Backup CR cascade 삭제 (위 C4 참조). 'cluster' 로 바뀌면 OK |
| 5 (monitor) | git revert + sync | OK |
| 6 (first project) | Application + namespace 삭제 | **High risk** — 실 데이터 있는 namespace 삭제 = PVC Delete = local-path 데이터 영구 손실. 사전 R2 backup 검증 필수 |
| 7 (automation) | git rm + workflow revert | OK — 매니페스트만 영향 |
| 8 | "되돌리기 어려움" | **불가** — helm uninstall 후 PVC delete 후 PV reclaim Delete 시 데이터 영구 손실. 위 H6 권고 사항 (Retain patch) 으로 완화 필요 |
| 9 | revert | OK |

**핵심 발견**: Phase 4·6·8 의 "롤백" 이 실질적으로 데이터 손실을 동반함에도 plan 에는 단일 명령으로 표시. P1 표 (위) 처럼 진입 전/진행 중/완료 후 분리 + 데이터 영향 명시 권장.

---

## 후속 액션 제안

### 즉시 (Phase 0 진입 전)
1. **C1 해결**: D-5 를 multi-source 로 확정 + plan Task 1.1/2.1/2.5/1.0 재작성. **(블로커)**
2. **C4 해결**: `backupOwnerReference: self` → `cluster` 일괄 grep + 수정 (5분). **(블로커)**
3. **C5 해결**: cert-manager values `installCRDs` → `crds.enabled` 전환 (5분). **(블로커)**
4. **C2 분할**: Phase 4 Task 4.6 을 두 시나리오로 분리 + design §8.2 절차 검증 시나리오 추가. **(블로커)**
5. **C3 검증**: Phase 0 Task 0.2 Step 3 에 operator metrics Service 키 검증 명시. **(블로커)**

### Phase 0 실행 중
6. H2 (kubeseal e2e), H3 (R2 Bucket Lock Terraform), H1 (apps AppProject), M2 (Alloy 형식), M3 (변수명 통일) 모두 Phase 0 박제 단계에서 함께 해결.

### Phase 6 진입 전
7. M4 (yq idempotency), M11 (NetworkPolicy 매니페스트), P6 (ResourceQuota), P7 (ignoreDifferences) 적용.

### Phase 8 진입 전
8. H6 (영구 데이터 손실 방지) 체크리스트 확장 + Retain patch 절차 적용.

### Phase 9 이후
9. P5 (백업 검증 자동화 CronJob 도입) 우선순위 상향 — out-of-scope §16 에서 P0 으로.
10. OpenEBS LocalPV 후속 plan 시점에 M9 (storage default 재평가) 함께 갱신.

---

## 종합 평가

설계 완성도는 **상위 5%** 수준 — 두 차례 리뷰 (v0.1→v0.2, v0.3→v0.4) 를 거치며 사용자가 운영하면서 누적한 메모리 13건 중 12건을 본문에 명시적으로 반영했다. 특히 v0.4 의 4개 리뷰 누락 보완 (I-0a, A1, M5, R15-R18) 이 Phase 8 의 Bitnami drift 라는 잠재 폭탄을 사전 발견·해결한 점은 모범적.

다만 plan 은 design 의 결정을 모두 반영하지 못한 채 v0.3 잔재 (C4 backupOwnerReference) 와 v0.4 결정 미적용 (C1 D-5 옵션, C5 cert-manager v1.15+ API) 이 남아 있어, 운영자가 plan 만 보고 그대로 따르면 첫 PR 부터 막힌다. **C1-C5 5건의 plan-design 정합 작업** 만 마치면 그 외는 small-medium 개선이라 Phase 0 진입 가능.

데이터 손실 리스크는 **실사용 0개** 라는 골든 타이밍 덕에 본질적으로 낮으나, Phase 8 helm uninstall 단계에서 운영자 실수로 잘못된 PVC 를 지울 위험만 추가 게이트 (H6) 로 막으면 안전하다.

OrbStack 12Gi 메모리 풋프린트 추정은 최대 5 프로젝트까지 안전 (~8Gi 누적 + 4Gi 헤드룸). 단일 노드 K3s 의 시스템 오버헤드 2.3Gi 이미 반영된 추정이라 신뢰할 만하다.

총평: **위 5개 Critical 이슈 해결 후 Phase 0 진입 GO**. 12-15일 추정은 calendar week 로 환산 시 3-4주 (homelab 파트타임 기준) 가 현실적.

---

## v1.1 반영 현황 (2026-04-20 갱신)

리뷰 항목별 반영 상태. 각 항목은 plan.md / design.md 의 실제 위치 증거와 함께 표시.

### Critical (5/5 반영 완료)

| ID | 상태 | 반영 위치 |
|---|---|---|
| C1 | ✅ **반영** | plan Task 0.1 (D-5 [x] 확정) · Task 1.0 (옵션 분기 제거, multi-source 스캐폴딩) · Task 1.1 (kustomization.yaml 정리) · Task 1.3 (sources[]) · Task 2.1 · Task 2.3 (sources[]) · design §A.1/§A.2 전면 재작성 · §12 Phase 0 D-5 확정 · §12 Phase 1.0 scope 변경 |
| C2 | ✅ **반영** | plan Task 4.6 → 4.6a/4.6b 분리 (동일 namespace vs 별도 namespace) · Task 4.7 Runbook 2종 · Task 9.1 Runbook 5종 · design Phase 9 5종 갱신 |
| C3 | ✅ **반영** | plan Task 0.2 Step 3 (monitoring 키 · helm template 사전 렌더) · Task 2.1 Step 2.5 (Service 생성 유무 사전 판정) · **Task 5.1.1 신규** (조건부 수동 metrics-service.yaml) · Task 5.2 Step 4 (operator 메트릭 8080 검증) · Task 5.2 Step 5 (Alloy scrape config 확장) |
| C4 | ✅ **반영** | plan Task 4.5 Step 1 ScheduledBackup `backupOwnerReference: cluster` · design 원본은 이미 cluster 였고 plan 잔재만 수정 |
| C5 | ✅ **반영** | plan Task 0.2 Step 3 (`crds` 키 확인) · Task 1.1 Step 2 (`crds.enabled` + `crds.keep`) · design §A.1 values 갱신 |

### High (6/6 반영 완료)

| ID | 상태 | 반영 위치 |
|---|---|---|
| H1 | ✅ **반영** | plan Task 0.7 Step 1a (apps AppProject 스냅샷 + 판정) · Task 6.3 Step 2 (엄격 검증 + dry-run sync) |
| H2 | ✅ **반영** | plan Task 0.8 Step 2 (로컬 seal e2e) · Step 3 (in-cluster 경로 검증 2 옵션) · Step 4 (ARC runner NP 점검 — M5 포함) |
| H3 | ✅ **반영** | plan Task 0.5 Step 5 (Terraform `cloudflare_r2_bucket_lock` + lifecycle) · Task 0.5 Step 6 (Lock 활성 확인) · **Task 4.4.5 신규** (Lock × Barman backup-delete 호환성 POC) |
| H4 | ✅ **반영** | plan Task 5.5 전면 재작성 (옵션 A GitOps 경유 즉시 발화 rule · 옵션 B amtool silence · UI 직접 편집 금지 명시) |
| H5 | ✅ **반영** | plan Task 5.4 알람 4번 expr 를 `cnpg.io/cluster` 라벨 기반으로 교체 (kube_persistentvolumeclaim_labels join) · Task 5.4 Step 2a (kube-state-metrics + 라벨 실존 검증) |
| H6 | ✅ **반영** | plan Task 8.0 Step 3 (10개 엄격 체크리스트) · Step 4 (Retain patch) · Step 5 (체크리스트 박제) · Task 8.3 Step 2 (명시적 `read` prompt) · Task 8.4 Step 0 (Retain 재확인) · Step 1.5 (30일 후 PV 삭제 GitHub Issue) |

### Medium (반영/보류 선별)

| ID | 상태 | 반영 위치 |
|---|---|---|
| M1 | ✅ **반영** | design §D3 "업그레이드 메서드" 섹션 신규 (inPlaceUpdates · SLO · Runbook 공지 절차) |
| M2 | ✅ **반영** | plan Task 0.4 Step 4 (Alloy config 형식 박제) · Task 5.1 dual-format fallback 제거 |
| M3 | ✅ **반영** | plan Task 0.9 (`R2_ACCOUNT_ID` 단일 변수명) · Task 0.5 Step 2 주석 일치 |
| M4 | ✅ **반영** | plan Task 7.4 Step 2 (`yq ... unique_by(.name)`) · Appendix TDD fixtures 에 duplicate role 케이스 추가 |
| M5 | ✅ **반영** (H2 와 결합) | plan Task 0.8 Step 4 (ARC runner NP 점검) |
| M6 | 📋 **§16 이관** | design §16 에 "Incremental backup 정책 (v1.1 후속 검토)" 추가 |
| M7 | ✅ **반영** | plan Task 6.4 Step 5 (sslmode disable → require 단계 검증 + 실패 시 역추적 가이드) |
| M8 | ✅ **반영** (H5 와 결합) | plan Task 5.4 Step 2b (`cnpg_collector_pg_wal_archive_status` 라벨 키 dump) |
| M9 | ✅ **반영** | plan Task 7.4 `storage` default `5Gi` → `10Gi` 상향 |
| M10 | ✅ **반영** | plan Task 0.9 Step 2 (grep 패턴 확장 + `TRAEFIK_NS` 치환 rule) |
| M11 | ✅ **반영** | plan Task 6.2 Step 4.5 (network-policy.yaml · CNPG pod 기준 ingress/egress) · Task 7.3 템플릿 추가 |

### Low (참고만, 반영 안 함)

| ID | 상태 | 사유 |
|---|---|---|
| L1 | ⏭️ skip | calendar week vs engineering day 구분은 가치 낮음, 운영자가 판단 가능 |
| L2-L8 | ⏭️ skip | 정보성 — design 문서 자체 가독성에 영향 없음 |

### 보완 권고 P

| ID | 상태 | 반영 위치 |
|---|---|---|
| P1 | ✅ **반영** | design §14 롤백 플랜 전면 재작성 (진입 전/진행 중/완료 후 + 데이터 영향 열 추가) + Critical Gate 명시 |
| P2 | ⏭️ skip | plan Task 4.7 에 이미 Runbook 초안 작성 Task 존재 (Phase 4 직후 commit). Phase 9 Task 9.1 에서 완성. 추가 조치 불필요 |
| P3 | ✅ **반영** | design Appendix B 전면 재작성 (메모리 13건 전체 체크 · 각 적용 위치 명시) |
| P4 | ⏭️ skip | 박제 파일 인덱스는 Phase 0 `_workspace/cnpg-migration/` 디렉토리 자체가 자연스러운 인덱스. 가치 낮음 |
| P5 | ✅ **반영** | design §16 에 백업 무결성 자동 검증 CronJob priority 상향 주석 추가 |
| P6 | ✅ **반영** | plan Task 6.2 Step 4.6 (resource-quota.yaml · 단일 노드 환경 프로젝트별 상한) |
| P7 | ✅ **반영** | plan Task 2.3 (ignoreDifferences 주석 placeholder) · Task 6.3 Step 1 (동일) · Task 6.4 Step 3a (drift 관찰 후 활성화 절차) |

### 미반영·Skip 요약

- **L1-L8**: 정보성 참고 사항으로 설계 품질에 영향 없음
- **P2**: 기존 plan 에 이미 반영되어 있음
- **P4**: 효용 대비 관리 비용 높음
- **M6**: v1.0 범위 밖 (§16 후속 검토)

### 다음 스텝

**Phase 0 진입 GO**. v1.1 은 본 리뷰의 Critical 5 + High 6 + 선별 Medium 10 + 보완 권고 5 를 모두 반영 완료. 운영자가 plan 을 순서대로 실행하면 첫 PR 단계부터 막히지 않도록 정합성 복구 완료.

*v1.1 revision end of review (2026-04-20)*
