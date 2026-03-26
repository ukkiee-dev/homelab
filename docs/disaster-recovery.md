# Homelab 재해복구 절차서

> 작성일: 2026-03-24
> 대상: Mac Mini M4 + OrbStack K3s + ArgoCD GitOps
> 도메인: `ukkiee.dev`

---

## 1. 복구 시나리오 분류

| 시나리오 | 심각도 | 데이터 손실 | 복구 시간 (예상) |
|----------|--------|-------------|-----------------|
| A. Pod/Service 장애 | 낮음 | 없음 | 1~5분 |
| B. OrbStack/K3s 재시작 | 낮음 | 없음 | 2~5분 |
| C. PVC 데이터 손상 | 중간 | 최대 24시간 (백업 주기) | 15~30분 |
| D. Mac Mini OS 재설치 | 높음 | PVC 데이터 | 1~2시간 |
| E. Mac Mini 하드웨어 고장 | 매우 높음 | 로컬 전체 | 2~4시간 (새 하드웨어 확보 후) |

---

## 2. 클러스터 외부에 반드시 백업해야 할 것

> 이 항목들이 없으면 Git에서 복구해도 서비스가 동작하지 않는다.

### 2.1 현재 필수 백업 항목

| 항목 | 설명 | 보관 위치 권장 |
|------|------|---------------|
| **SealedSecrets 키페어** | 컨트롤러의 암호화/복호화 키. 이것 없이는 기존 SealedSecret YAML 복호화 불가. | Vaultwarden (다른 기기에서 접근 가능한 경우) 또는 클라우드 스토리지 |
| **부트스트랩 시크릿 원본값** | CF API Token, CF Tunnel Token, VW Admin Token, BW Client ID/Secret, Master Password | Vaultwarden (비밀번호 매니저) |
| **Vaultwarden DB 백업** | 비밀번호 매니저 데이터. 모든 다른 시크릿의 원본이 여기에 있음. | 클라우드 스토리지 / 외부 디스크 |
| **PVC 백업 tarball** | `backup.sh` 출력물. Uptime Kuma, AdGuard, Portainer, Traefik ACME 등. | 외부 디스크 / NAS / 클라우드 |

### 2.2 향후 추가될 백업 항목 (구현 계획 Phase별)

| Phase | 항목 | 설명 |
|-------|------|------|
| Phase 1 | Grafana 대시보드 export | 커스텀 대시보드가 있다면 JSON export 백업 |
| Phase S | **Immich 사진 라이브러리** | **외장 SSD 원본 + R2 Restic 백업. SSD 고장 시 R2만 유효.** |
| Phase S | **Immich PostgreSQL pgdump** | 메타데이터 + 벡터 임베딩. 매일 02:50 KST 자동 덤프. |
| Phase 4 | PostgreSQL pgdump | API 서버 + Infisical DB 데이터 |
| Phase 5 | **Infisical ENCRYPTION_KEY** | **분실 시 전체 시크릿 복구 불가. 최우선 백업 대상.** |
| Phase 5 | Infisical AUTH_SECRET | 인증 키 |

### 2.3 백업 불필요 항목 (Git에서 복구 가능)

| 항목 | 이유 |
|------|------|
| K8s 매니페스트 (Deployment, Service, ConfigMap 등) | Git 저장소에 전체 선언 |
| ArgoCD Application 정의 | `argocd/` 디렉토리에 전체 선언 |
| Helm 차트 값 | `k8s/base/*/values.yaml`에 전체 선언 |
| NetworkPolicy | `k8s/base/network-policies/`에 전체 선언 |
| Namespace 정의 | `k8s/base/namespaces/`에 전체 선언 |
| 스크립트 | `scripts/`, `Makefile`에 전체 선언 |

---

## 3. 시나리오별 복구 절차

### 시나리오 A: Pod/Service 장애

**증상:** 특정 서비스가 응답하지 않음. Uptime Kuma 또는 AlertManager 알림 수신.

```bash
# 1. 상태 확인
make pods
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# 2. Pod 로그 확인
make logs POD=<pod-name> NS=<namespace>

# 3-a. Pod가 CrashLoopBackOff인 경우
kubectl describe pod <pod-name> -n <namespace>
# OOM → 리소스 limit 확인
# Config 오류 → ConfigMap/Secret 확인

# 3-b. Pod가 Pending인 경우
# PVC bound 확인
make pvc

# 4. 단순 재시작으로 해결 가능한 경우
make restart NAME=<deployment-name> NS=<namespace>

# 5. ArgoCD가 자동 복구 (selfHeal: true)
# 대부분의 경우 ArgoCD가 자동으로 원래 상태로 복구한다.
```

**복구 시간:** 1~5분

---

### 시나리오 B: OrbStack/K3s 재시작

**증상:** Mac Mini 재부팅 또는 OrbStack 재시작 후 서비스 일시 중단.

```bash
# 1. OrbStack 시작 확인
orbctl status

# 2. K8s 컨텍스트 확인
kubectl config use-context orbstack

# 3. Pod 상태 확인 (자동 복구 대기)
watch kubectl get pods -A

# 4. PVC 자동 마운트 확인
make pvc

# 5. Cloudflare Tunnel 재연결 확인 (자동)
kubectl logs -n networking deployment/cloudflared --tail=20
```

**복구 시간:** 2~5분 (Pod가 자동으로 재스케줄됨)

**주의:** StatefulSet(Vaultwarden, Uptime Kuma, AdGuard)은 PVC가 정상 마운트될 때까지 시작하지 않음. PVC가 Bound 상태인지 확인.

---

### 시나리오 C: PVC 데이터 손상

**증상:** 서비스 시작되지만 데이터가 깨져있음 (예: Vaultwarden DB 손상, AdGuard 설정 초기화)

```bash
# 1. 해당 서비스 스케일 다운
kubectl scale statefulset/<service> -n apps --replicas=0

# 2. 최신 백업 확인
ls -la backups/

# 3. 백업 무결성 검증
sha256sum -c backups/<TIMESTAMP>.tar.gz.sha256

# 4. 백업 압축 해제
tar -xzf backups/<TIMESTAMP>.tar.gz -C /tmp/restore

# 5. 데이터 복원
make migrate SVC=<service>
# 복원 가능 서비스: vaultwarden, uptime-kuma, adguard, traefik, portainer

# 6. 서비스 스케일 업
kubectl scale statefulset/<service> -n apps --replicas=1

# 7. 정상 동작 확인
kubectl logs -f statefulset/<service> -n apps
```

**복구 시간:** 15~30분
**데이터 손실:** 최대 24시간 (백업 주기에 따라)

**Vaultwarden 특별 주의:**
- Vaultwarden은 모든 비밀번호의 원본. 데이터 손실 시 영향이 가장 큼.
- 복구 후 VW-K8s-Secrets가 60초 내에 자동으로 앱 시크릿을 다시 동기화.

---

### 시나리오 D: Mac Mini OS 재설치

**증상:** macOS를 클린 재설치했거나, OrbStack K8s 클러스터를 삭제 후 재생성.

#### 사전 조건
- [ ] Git 저장소 접근 가능 (github.com/ukkiee-dev/homelab)
- [ ] 부트스트랩 시크릿 원본값 접근 가능 (Vaultwarden 다른 기기 또는 외부 백업)
- [ ] PVC 백업 tarball 존재 (외부 디스크/NAS)
- [ ] **Full Disk Access 설정** — 터미널 앱 + OrbStack (외장 SSD 접근에 필수)
- [ ] **외장 SSD 소유권 활성화** — `sudo diskutil enableOwnership /Volumes/ukkiee`
- [ ] **AdGuard DNS 캐시 클리어** — 새 서브도메인 추가 후 필수

#### 복구 순서

```bash
# === Step 1: 환경 준비 (10분) ===

# OrbStack 설치
brew install orbstack
# OrbStack → Settings → Kubernetes 활성화

# 저장소 클론
git clone https://github.com/ukkiee-dev/homelab.git
cd homelab

# CLI 도구 설치
make install-tools
./scripts/setup.sh context
./scripts/setup.sh verify

# === Step 2: SealedSecrets 복원 (5분) ===

# 방법 A: 기존 키페어가 백업되어 있는 경우
kubectl create namespace sealed-secrets
kubectl apply -f /path/to/sealed-secrets-key-backup.yaml
kubectl apply -k k8s/base/sealed-secrets

# 방법 B: 키페어가 없는 경우 (새로 생성 → 모든 SealedSecret 재암호화 필요)
kubectl apply -k k8s/base/sealed-secrets
# 새 컨트롤러가 새 키페어 생성
make bootstrap-secrets
# 부트스트랩 시크릿 원본값을 다시 입력하여 새 SealedSecret YAML 생성
git add -A && git commit -m "Re-seal secrets with new controller key"
git push

# === Step 3: ArgoCD 배포 (5분) ===

# 네임스페이스 생성
kubectl apply -k k8s/base/namespaces

# ArgoCD 수동 배포 (다른 앱들을 관리하기 위해 먼저 필요)
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd -f k8s/base/argocd/values.yaml

# ArgoCD 초기 admin 비밀번호 확인
make argocd-password

# App-of-Apps 배포
kubectl apply -f argocd/app-of-apps.yaml

# === Step 4: ArgoCD가 모든 서비스 자동 배포 (10~15분) ===

# 동기화 상태 확인
make status
# 또는
make port-forward  # localhost:8080에서 ArgoCD UI 접근

# 모든 앱이 Synced + Healthy 될 때까지 대기
watch kubectl get applications -n argocd

# === Step 5: 데이터 복원 (10~15분) ===

# 백업 tarball을 로컬에 복사
cp /path/to/external/backups/<TIMESTAMP>.tar.gz backups/

# 압축 해제
cd backups && tar -xzf <TIMESTAMP>.tar.gz && cd ..

# 데이터 복원 (각 서비스 순서대로)
make migrate SVC=traefik        # ACME 인증서 복원 (Let's Encrypt 재발급 방지)
make migrate SVC=vaultwarden    # 비밀번호 DB 복원 (가장 중요)
make migrate SVC=adguard        # DNS 설정 복원
make migrate SVC=uptime-kuma    # 모니터링 설정 복원
make migrate SVC=portainer      # 컨테이너 설정 복원

# 서비스 재시작 (새 데이터 로드)
kubectl rollout restart statefulset -n apps
kubectl rollout restart deployment -n apps

# === Step 6: 검증 (10분) ===

make health
make pods
make pvc

# 외부 접근 확인
# vault.ukkiee.dev, status.ukkiee.dev 접속 테스트
# Tailscale으로 home.ukkiee.dev, argo.ukkiee.dev 등 접근 확인
```

**복구 시간:** 1~2시간
**데이터 손실:** 마지막 백업 시점 이후의 데이터

---

### 시나리오 E: Mac Mini 하드웨어 고장

**증상:** Mac Mini가 물리적으로 동작하지 않음.

#### 사전 조건
- [ ] **새 Mac Mini (또는 다른 macOS/Linux 머신)** 확보
- [ ] Git 저장소 접근 가능
- [ ] 부트스트랩 시크릿 원본값 접근 가능
- [ ] PVC 백업 tarball이 **외부 저장소에 존재** (외부 디스크/NAS/클라우드)
- [ ] SealedSecrets 키페어 백업 (없으면 재생성 가능하나 모든 SealedSecret 재암호화 필요)

#### 복구 순서

시나리오 D와 동일. 단, PVC 백업이 외부 저장소에 없으면 **데이터 전체 손실**.

**치명적 손실 방지를 위한 핵심:**
1. `backup.sh` 출력을 외부 저장소에 자동 복사하는 크론잡 설정
2. SealedSecrets 키페어를 Vaultwarden(다른 기기에서 접근 가능)에 저장
3. 부트스트랩 시크릿 원본값을 Vaultwarden에 저장

**복구 시간:** 2~4시간 (새 하드웨어 셋업 포함)

---

## 4. 향후 Phase 완료 후 복구 절차 변경점

### Phase 1 완료 후 (Prometheus + Grafana + Loki)

추가 복원 항목:
```bash
# Grafana PVC 복원 (커스텀 대시보드)
# Prometheus는 TSDB 손실되어도 재수집 가능 — 복원 우선순위 낮음
# Loki는 로그 손실되어도 서비스 영향 없음 — 복원 선택
```

### Phase S 완료 후 (Immich + 외장 SSD)

추가 복구 시나리오:

**시나리오 F: 외장 SSD 분리/고장**
```bash
# 증상: Immich Pod CrashLoop, launchd 워치독 알림 수신

# SSD 분리 (물리적 연결 해제)
# 1. 재연결 후 마운트 확인
diskutil list | grep ukkiee
# 2. 마운트 안 되면 수동 마운트
diskutil mount /dev/diskN
# 3. Pod 재시작
kubectl rollout restart deployment -n immich

# SSD 고장 (복구 불가)
# 1. 새 SSD 준비 + APFS 포맷 + 디렉토리 구조 재생성
# 2. Immich PostgreSQL 복원 (내장 SSD pgdump 또는 R2)
pg_restore -h <host> -U immich -d immich /path/to/immich.sql
# 3. 사진 라이브러리 복원 (R2 Restic — 시간 소요 큼)
restic -r s3:immich-backup restore latest --target /Volumes/ukkiee/immich
# 4. 썸네일은 Immich가 자동 재생성 (시간 소요)
# 5. Pod 재시작
```

**복구 시간:** SSD 분리 5분, SSD 고장 시 수시간~수일 (R2 복원)
**데이터 손실:** 최대 24시간 (마지막 Restic 백업 이후)

### Phase 4 완료 후 (PostgreSQL)

추가 복원 항목:
```bash
# PostgreSQL pgdump 복원 (API 서버 데이터)
psql -h <host> -U <user> -d <database> < /path/to/backup.sql
```

### Phase 5 완료 후 (Infisical)

**복구 절차가 크게 변경됨:**

```
[현재]
SealedSecrets 키페어 복원 → bootstrap-secrets.sh → ArgoCD 배포 → 데이터 복원

[Phase 5 이후]
Infisical 부트스트랩 시크릿 수동 생성 → PostgreSQL 복원 → Infisical 배포
→ Infisical Operator가 모든 K8s Secret 자동 동기화 → ArgoCD 배포 → 데이터 복원
```

**핵심 변경:**
- SealedSecrets 키페어 대신 **Infisical ENCRYPTION_KEY**가 최우선 백업 대상
- bootstrap-secrets.sh 대신 Infisical bootstrap 스크립트 사용
- VW-K8s-Secrets 동기화 대기 불필요 (Infisical Operator가 즉시 동기화)
- SealedSecrets 컨트롤러 배포 불필요

---

## 5. SealedSecrets 키페어 백업 방법

> 이 키를 잃으면 기존 SealedSecret YAML을 복호화할 수 없다. 새 키로 재암호화 가능하지만, 원본 시크릿 값이 필요하다.

```bash
# === 키페어 내보내기 ===
kubectl get secret -n sealed-secrets -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-key-backup.yaml

# === 안전한 곳에 보관 ===
# 옵션 1: Vaultwarden에 첨부 파일로 저장
# 옵션 2: 암호화된 외부 저장소
# 옵션 3: 다른 기기의 안전한 디렉토리

# === 복원 시 ===
kubectl create namespace sealed-secrets
kubectl apply -f sealed-secrets-key-backup.yaml
# 그 후 sealed-secrets 컨트롤러 배포하면 기존 키 사용
```

---

## 6. 백업 자동화 권장 설정

### 현재: backup.sh (수동 실행)

```bash
# 수동 실행
make backup
```

### 권장: CronJob으로 자동화

```bash
# crontab에 추가 (Mac Mini 로컬)
# 매일 03:00 KST에 백업 실행
0 3 * * * cd /path/to/homelab && ./backup.sh >> /var/log/homelab-backup.log 2>&1

# 매주 일요일 04:00에 외부 저장소로 복사 (iCloud, NAS, 또는 S3)
0 4 * * 0 rsync -avz /path/to/homelab/backups/ /path/to/external/backups/
```

### 권장: 백업 알림

```bash
# backup.sh 마지막에 알림 추가
curl -X POST https://api.getmoshi.app/api/webhook \
  -H "Content-Type: application/json" \
  -d '{"token": "...", "title": "백업", "message": "Homelab 백업 완료: '$(date +%Y%m%d_%H%M%S)'"}'
```

---

## 7. 복구 검증 체크리스트

### 기본 인프라

- [ ] OrbStack K8s 클러스터 정상
- [ ] 모든 namespace 존재 (apps, argocd, traefik-system, networking, sealed-secrets 등)
- [ ] SealedSecrets 컨트롤러 동작
- [ ] ArgoCD 모든 Application이 Synced + Healthy

### 네트워킹

- [ ] Traefik Pod Running + TLS 인증서 유효
- [ ] Cloudflare Tunnel 연결 (cloudflared Pod 정상)
- [ ] Tailscale Operator 동작
- [ ] `vault.ukkiee.dev` 외부 접근 가능
- [ ] `status.ukkiee.dev` 외부 접근 가능
- [ ] `home.ukkiee.dev` Tailscale 접근 가능
- [ ] `argo.ukkiee.dev` Tailscale 접근 가능

### 서비스

- [ ] Vaultwarden 로그인 정상 + 데이터 복원 확인
- [ ] Homepage 위젯(AdGuard, Uptime Kuma) 정상 표시
- [ ] AdGuard DNS 쿼리 정상 응답
- [ ] Uptime Kuma 모니터링 대상 정상
- [ ] Portainer 로그인 정상
- [ ] Dozzle 로그 뷰어 동작
- [ ] ARC Runner가 GitHub에 연결

### 시크릿

- [ ] VW-K8s-Secrets가 Vaultwarden에서 시크릿 동기화 중
- [ ] 각 서비스의 `secretKeyRef`가 정상 (Pod 시작 시 Secret 참조 오류 없음)

### 데이터

- [ ] 모든 PVC Bound 상태
- [ ] Vaultwarden DB 데이터 존재 (로그인 후 비밀번호 목록 확인)
- [ ] Uptime Kuma 모니터 설정 존재
- [ ] AdGuard 필터/설정 복원
- [ ] Traefik ACME 인증서 존재 (Let's Encrypt 재발급 없이 동작)

---

## 8. 복구 시간 목표 (RTO/RPO)

| 지표 | 현재 | 목표 |
|------|------|------|
| **RTO** (복구 시간 목표) | 2~4시간 (시나리오 E) | 유지 |
| **RPO** (데이터 손실 허용 범위) | 최대 24시간 (수동 백업) | **1시간 이내** (자동 백업 도입 시) |

RPO 개선 방법:
- `backup.sh`를 CronJob으로 매시간 실행
- PostgreSQL WAL 기반 연속 백업 (Phase 4 이후)
- 외부 저장소 자동 동기화

---

## 9. 정기 복구 훈련

> 백업이 있어도 복원이 안 되면 의미 없다.

### 분기 1회 권장 확인 사항

- [ ] `backup.sh` 출력 tarball의 무결성 검증 (sha256sum)
- [ ] 임의의 서비스 1개를 선택하여 PVC 복원 테스트 (`migrate-data.sh`)
- [ ] SealedSecrets 키페어 백업 파일 존재 확인
- [ ] 부트스트랩 시크릿 원본값이 Vaultwarden에 최신 상태로 저장되어 있는지 확인
- [ ] 외부 저장소의 백업이 최신인지 확인

### Phase 5 (Infisical) 이후 추가 확인

- [ ] Infisical ENCRYPTION_KEY 외부 백업 존재 확인
- [ ] PostgreSQL pgdump 복원 테스트
- [ ] Infisical에서 시크릿 조회 → K8s Secret 동기화 확인
