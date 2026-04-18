# Homelab 재해복구 절차서

> 최종 수정: 2026-04-18
> 대상: Mac Mini M4 + OrbStack K3s + ArgoCD GitOps
> 도메인: `ukkiee.dev`

---

## 1. 현재 서비스 구성

### Infrastructure (infra/)

| 서비스 | 배포 방식 | Namespace |
|--------|----------|-----------|
| Traefik | Helm | traefik-system |
| Cloudflared | Kustomize | networking |
| ArgoCD | Helm | argocd |
| Sealed Secrets | Helm | kube-system |
| Network Policies | Kustomize | (각 namespace) |
| ARC Runners | Helm | actions-runner-system |
| Tailscale Operator | Helm | tailscale-system |

### Applications (apps/)

| 서비스 | 배포 방식 | Namespace | 데이터 |
|--------|----------|-----------|--------|
| Homepage | Kustomize | apps | ConfigMap (stateless) |
| AdGuard Home | Kustomize | apps | PVC (설정 + 필터) |
| Uptime Kuma | Kustomize | apps | PVC (모니터링 설정) |
| PostgreSQL | Kustomize | apps | PVC + CronJob pg_dump 백업 |
| Test Web | Kustomize | test-web | - (CI/CD 테스트용) |

### Monitoring (monitoring/)

| 서비스 | 배포 방식 | 데이터 |
|--------|----------|--------|
| Victoria Metrics | Kustomize | TSDB (손실 시 재수집 가능) |
| Grafana | Kustomize | PVC (대시보드 + 설정) |
| Alloy | Kustomize | Stateless (로그 수집기) |
| Victoria Logs | Kustomize | 로그 (손실 허용) |

### 접근 경로

- **Cloudflare Tunnel (공개):** test-web.ukkiee.dev 등 public 앱
- **Tailscale-only (내부):** argo, traefik, home, status, dns, grafana, api 등
- **시크릿 관리:** SealedSecrets

---

## 2. 복구 시나리오

| 시나리오 | 심각도 | 데이터 손실 | 복구 시간 |
|----------|--------|-------------|----------|
| A. Pod/Service 장애 | 낮음 | 없음 | 1~5분 |
| B. OrbStack/K3s 재시작 | 낮음 | 없음 | 2~5분 |
| C. PVC 데이터 손상 | 중간 | 최대 24시간 | 15~30분 |
| D. Mac Mini OS 재설치 | 높음 | PVC 데이터 | 1~2시간 |
| E. Mac Mini 하드웨어 고장 | 매우 높음 | 로컬 전체 | 2~4시간 |

---

## 3. 클러스터 외부에 반드시 백업해야 할 것

| 항목 | 설명 | 보관 위치 |
|------|------|-----------|
| **SealedSecrets 키페어** | 이것 없이는 기존 SealedSecret YAML 복호화 불가 | 비밀번호 매니저 / 클라우드 스토리지 |
| **시크릿 원본값** | CF API Token, Tunnel Token, OAuth 키 등 | 비밀번호 매니저 |
| **Tailscale OAuth** | operator-oauth Secret (client_id, client_secret) | 비밀번호 매니저 |
| **PVC 백업** | `backup.sh` 출력 (Uptime Kuma, AdGuard conf) | 외장 SSD `/Volumes/ukkiee/homelab/backups` (LaunchAgent 매월 1일 04:00 KST + `make backup` 수동) |
| **PostgreSQL pgdump** | PostgreSQL DB (CronJob 매일 03:00 KST 자동 덤프) | apps namespace PVC |

### 백업 불필요 (Git에서 복구 가능)

- K8s 매니페스트: `manifests/` 디렉토리 전체
- ArgoCD Application 정의: `argocd/` 디렉토리
- Helm values: `manifests/*/values*.yaml`
- NetworkPolicy, Namespace 정의
- `backup.sh`, `scripts/setup.sh`, `Makefile`

---

## 4. 시나리오별 복구 절차

### A. Pod/Service 장애

```bash
# 상태 확인
make pods
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
make logs POD=<pod-name> NS=<namespace>

# ArgoCD selfHeal이 대부분 자동 복구
# 필요 시 수동 재시작
make restart NAME=deployment/<name> NS=<namespace>
```

### B. OrbStack/K3s 재시작

```bash
orbctl status
kubectl config use-context orbstack
watch kubectl get pods -A
make pvc  # PVC Bound 상태 확인
```

Pod는 자동 재스케줄됨. StatefulSet은 PVC 마운트 대기 후 시작.

### C. PVC 데이터 손상

```bash
# 서비스 스케일 다운
kubectl scale deployment/<service> -n apps --replicas=0

# 앱별 최신 백업에서 복원 (namespace/app 구조)
BACKUP_ROOT=/Volumes/ukkiee/homelab/backups
LATEST=$(ls -t ${BACKUP_ROOT}/<app>/*.tar.gz | head -1)
mkdir -p /tmp/restore && tar -xzf "${LATEST}" -C /tmp/restore

# kubectl cp로 데이터 복원 후 스케일 업
kubectl cp /tmp/restore/. apps/<pod>:<container-path>
kubectl scale deployment/<service> -n apps --replicas=1
```

### D. Mac Mini OS 재설치

#### 사전 조건
- [ ] Git 저장소 접근 가능 (github.com/ukkiee-dev/homelab)
- [ ] 시크릿 원본값 접근 가능 (비밀번호 매니저)
- [ ] PVC 백업 tarball (외부 디스크/NAS)
- [ ] Full Disk Access: 터미널 앱 + OrbStack (외장 SSD 접근 필수)
- [ ] `sudo diskutil enableOwnership /Volumes/ukkiee`

#### 복구 순서

```bash
# === Step 1: 환경 준비 (10분) ===
brew install orbstack
# OrbStack → Settings → Kubernetes 활성화

git clone https://github.com/ukkiee-dev/homelab.git
cd homelab
./scripts/setup.sh tools
./scripts/setup.sh context
./scripts/setup.sh verify

# === Step 2: SealedSecrets 복원 (5분) ===

# 방법 A: 기존 키페어 백업이 있는 경우
kubectl create namespace kube-system 2>/dev/null || true
kubectl apply -f /path/to/sealed-secrets-key-backup.yaml

# 방법 B: 키페어 없는 경우 → 모든 SealedSecret 재암호화 필요
# 새 컨트롤러가 새 키페어 생성 → 시크릿 원본값으로 재생성

# === Step 3: Tailscale OAuth Secret 생성 ===
kubectl create namespace tailscale-system
kubectl create secret generic operator-oauth \
  -n tailscale-system \
  --from-literal=client_id=<ID> \
  --from-literal=client_secret=<SECRET>

# === Step 4: ArgoCD 배포 (5분) ===
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace \
  -f manifests/infra/argocd/values.yaml

make argocd-password

# App-of-Apps 배포
kubectl apply -f argocd/root.yaml

# === Step 5: 자동 배포 대기 (10~15분) ===
watch kubectl get applications -n argocd

# === Step 6: 데이터 복원 (10~15분) ===
# PVC 백업에서 복원: Uptime Kuma, AdGuard, Traefik ACME
# PostgreSQL은 CronJob 백업에서 복원

# === Step 7: 검증 ===
make health
make pods
make pvc
```

### E. Mac Mini 하드웨어 고장

시나리오 D와 동일. PVC 백업이 외부에 없으면 데이터 전체 손실.

---

## 5. SealedSecrets 키페어 백업

```bash
# 내보내기
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-key-backup.yaml

# 복원 시
kubectl apply -f sealed-secrets-key-backup.yaml
# 이후 sealed-secrets 컨트롤러 배포하면 기존 키 사용
```

---

## 6. 자동 백업 현황

| 대상 | 방식 | 주기 | 보존 |
|------|------|------|------|
| Uptime Kuma, AdGuard conf | `backup.sh` → 외장 SSD (LaunchAgent `dev.ukkiee.homelab-backup`) + 수동 `make backup` | 매월 1일 04:00 KST | 최근 7개 (≈7개월) |
| PostgreSQL | CronJob `postgresql-backup` | 매일 03:00 KST | 7일 |

---

## 7. 복구 검증 체크리스트

### 인프라
- [ ] OrbStack K8s 클러스터 정상
- [ ] 모든 namespace 존재
- [ ] SealedSecrets 컨트롤러 동작 (kube-system)
- [ ] ArgoCD 모든 Application Synced + Healthy

### 네트워킹
- [ ] Traefik Pod Running + TLS 인증서 유효
- [ ] Cloudflare Tunnel 연결 (cloudflared Pod 정상)
- [ ] Tailscale Operator 동작
- [ ] 공개 서비스 (Tunnel) 외부 접근 가능
- [ ] `argo.ukkiee.dev` Tailscale 접근 가능

### 서비스
- [ ] Homepage 위젯 정상 표시
- [ ] AdGuard DNS 쿼리 정상 응답
- [ ] Uptime Kuma 모니터링 대상 정상
- [ ] PostgreSQL 접속 가능
- [ ] ARC Runner가 GitHub에 연결
- [ ] Grafana 대시보드 로딩 정상

### 데이터
- [ ] 모든 PVC Bound 상태
- [ ] Uptime Kuma 모니터 설정 존재
- [ ] AdGuard 필터/설정 복원
- [ ] Traefik ACME 인증서 존재
- [ ] PostgreSQL 백업 CronJob 정상 실행

---

## 8. 트러블슈팅 참고

### 외장 SSD Permission Denied (macOS TCC)
System Settings > Privacy & Security > Full Disk Access에서 터미널 앱 + OrbStack 추가 후 재시작.
`sudo diskutil enableOwnership /Volumes/ukkiee` 실행 필수.

### 새 서브도메인 DNS 캐시 문제
Cloudflare에 DNS 추가 후 접속 불가 시:
1. AdGuard 웹 UI > Settings > DNS settings > Clear cache
2. `sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder`

### DNS 아키텍처
- **내부 서비스 (Tailscale-only):** A 레코드 → Tailscale IP (100.112.20.3)
- **공개 서비스 (Cloudflare Tunnel):** CNAME → Tunnel (Proxied)
