# Mermaid 다이어그램 패턴

이 프로젝트의 아키텍처를 시각화하기 위한 Mermaid 다이어그램 패턴과 프로젝트 고유 데이터.

---

## 1. 네트워크 토폴로지

```mermaid
flowchart LR
  subgraph External
    Internet((Internet))
    CF[Cloudflare CDN]
    TS[Tailscale Network]
  end

  subgraph networking
    cfd[cloudflared]
  end

  subgraph traefik-system
    TW["Traefik :80 (web)"]
    TWS["Traefik :443 (websecure)"]
  end

  subgraph apps
    svc1[Service A]
    svc2[Service B]
  end

  Internet --> CF
  CF -->|"Tunnel"| cfd
  cfd -->|"HTTP"| TW
  TW -->|"+ security-headers\n+ gzip\n+ rate-limit"| svc1

  TS -->|"Tailscale VPN"| TWS
  TWS -->|"+ tailscale-only\n+ security-headers\n+ gzip"| svc2
```

화살표 라벨에 Traefik 미들웨어 체인을 명시한다.

---

## 2. 서비스 의존성 맵

```mermaid
flowchart TD
  subgraph "infra (sync wave -1)"
    argocd[ArgoCD]
    traefik[Traefik]
    cfd[cloudflared]
    sealed[SealedSecrets]
    ts[Tailscale]
    arc[ARC Runners]
  end

  subgraph "apps (sync wave 0)"
    homepage[Homepage]
    adguard[AdGuard]
    uptime[Uptime Kuma]
    pg[PostgreSQL]
    immich[Immich]
  end

  subgraph "monitoring (sync wave 1)"
    vm[VictoriaMetrics]
    grafana[Grafana]
    alloy[Alloy]
    vl[VictoriaLogs]
  end

  immich --> pg
  grafana --> vm
  grafana --> vl
  alloy --> vm
  alloy --> vl
  homepage -.->|"K8s API"| argocd
```

실선(-->)은 런타임 의존, 점선(-.->)은 데이터 조회 의존.

---

## 3. 배포 파이프라인

```mermaid
sequenceDiagram
  participant Dev as 외부 레포
  participant GHA as GitHub Actions
  participant HL as homelab 레포
  participant Argo as ArgoCD
  participant K8s as K8s 클러스터

  Dev->>GHA: push (image build)
  GHA->>GHA: Docker build + push to GHCR
  GHA->>HL: workflow_call → _update-image.yml
  HL->>HL: yq로 이미지 태그 갱신 + git push
  Argo->>HL: 변경 감지 (3분 주기)
  Argo->>K8s: selfHeal 동기화
  K8s->>K8s: Rolling Update
```

---

## 4. 앱 라이프사이클

```mermaid
stateDiagram-v2
  [*] --> Created: setup-app action
  Created --> Running: ArgoCD sync
  Running --> Updated: _update-image.yml
  Updated --> Running: ArgoCD selfHeal
  Running --> ConfigChanged: update-app-config.yml
  ConfigChanged --> Running: ArgoCD selfHeal
  Running --> Teardown: teardown.yml
  Teardown --> [*]: DNS+Tunnel+매니페스트+ArgoCD 제거
```

---

## 5. 백업/복원 흐름

```mermaid
flowchart TD
  subgraph "수동 백업 (backup.sh)"
    B1[Uptime Kuma PVC] -->|"kubectl cp"| Local[로컬 backups/]
    B2[AdGuard PVC] -->|"kubectl cp"| Local
    B3[Traefik ACME] -->|"kubectl cp"| Local
  end

  subgraph "자동 백업 (CronJob)"
    C1[PostgreSQL CronJob] -->|"pg_dump 매일 03:00"| PVC1[PVC backup/]
    C2[Immich CronJob] -->|"DB dump"| PVC2[PVC backup/]
  end

  subgraph "외부 필수 백업"
    E1[SealedSecrets 키페어]
    E2[시크릿 원본값]
    E3[Tailscale OAuth]
  end
```

---

## 6. 장애 도메인

```mermaid
flowchart TD
  subgraph "SPOF: Mac Mini"
    node[K3s Node]
    ssd[외장 SSD]
  end

  subgraph "SPOF: Cloudflare"
    dns[DNS]
    tunnel[Tunnel]
  end

  subgraph "복구 우선순위"
    P1["1. SealedSecrets"]
    P2["2. ArgoCD"]
    P3["3. Traefik + cloudflared"]
    P4["4. Tailscale"]
    P5["5. 앱 자동 배포"]
  end

  node --> P1
  P1 --> P2
  P2 --> P3
  P3 --> P4
  P4 --> P5
```

장애 도메인 다이어그램에서는 SPOF를 빨간색 서브그래프, 복구 순서를 번호로 명시한다.

---

## 작성 규칙

### 서브그래프
- 네임스페이스 또는 계층별로 서브그래프를 그룹핑
- 서브그래프 제목에 sync wave 또는 역할을 명시

### 화살표
- 실선(`-->`): 런타임 의존, 트래픽 흐름
- 점선(`-.->`): 데이터 조회, 참조 관계
- 굵은선(`==>`): 크리티컬 경로

### 라벨
- 프로토콜/포트: `|"HTTP :80"|`
- 미들웨어/처리: `|"+ gzip\n+ rate-limit"|`
- 조건: `|"실패 시"|`

### 크기 제어
- 다이어그램당 노드 15개 이내
- 초과 시 overview(전체 구조) + detail(영역별 상세)로 분할
- overview에서 detail로 링크: `자세한 내용은 [네트워크 상세](#네트워크-상세) 참조`
