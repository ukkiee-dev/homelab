# Homelab 프로젝트 컨벤션

이 문서는 homelab 프로젝트의 매니페스트 작성·인프라 구성에 적용되는 컨벤션을 정리한다. 에이전트는 이 컨벤션을 준수하여 일관성을 유지한다.

## 목차

1. [디렉토리 구조](#디렉토리-구조)
2. [라벨링](#라벨링)
3. [보안 컨텍스트](#보안-컨텍스트)
4. [리소스 제한](#리소스-제한)
5. [ArgoCD 패턴](#argocd-패턴)
6. [네트워킹](#네트워킹)
7. [SealedSecrets](#sealedsecrets)
8. [모니터링 통합](#모니터링-통합)
9. [네임스페이스 전략](#네임스페이스-전략)

---

## 디렉토리 구조

```
homelab/
├── argocd/
│   ├── root.yaml                      # App-of-Apps 엔트리포인트
│   └── applications/
│       ├── infra/                     # 인프라 ArgoCD Applications
│       ├── apps/                      # 앱 ArgoCD Applications
│       └── monitoring/                # 모니터링 ArgoCD Applications
├── manifests/
│   ├── infra/<service>/               # 인프라 매니페스트 (sync wave -1)
│   │   └── kustomization.yaml + 리소스 파일들
│   ├── apps/<app>/                    # 앱 매니페스트 (sync wave 0)
│   │   └── kustomization.yaml + 리소스 파일들
│   └── monitoring/<component>/        # 모니터링 매니페스트 (sync wave 1)
│       └── kustomization.yaml + 리소스 파일들
├── terraform/                         # Cloudflare DNS IaC
│   ├── apps.json                      # 앱 레지스트리 (이름→서브도메인)
│   └── dns.tf                         # CNAME 레코드 생성
└── .github/
    ├── actions/setup-app/             # 앱 온보딩 composite action
    ├── scripts/                       # 터널 관리 스크립트
    └── workflows/                     # CI/CD 워크플로우
```

각 앱 디렉토리는 **플랫 구조** (overlay 없음):
```
manifests/apps/<app>/
├── kustomization.yaml
├── deployment.yaml (또는 statefulset.yaml)
├── service.yaml
├── ingressroute.yaml
├── sealed-secret.yaml (필요시)
├── configmap.yaml (필요시)
└── pv.yaml / pvc.yaml (필요시)
```

`kustomization.yaml`은 리소스 목록만 포함:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - ingressroute.yaml
```

---

## 라벨링

모든 리소스에 4개 표준 라벨을 포함한다:

```yaml
metadata:
  labels:
    app.kubernetes.io/name: <app-name>          # 컴포넌트 식별자
    app.kubernetes.io/component: <role>          # 기능 역할 (server, db, cache, proxy 등)
    app.kubernetes.io/part-of: homelab           # 항상 homelab
    app.kubernetes.io/managed-by: argocd         # 항상 argocd
```

Deployment의 `spec.selector.matchLabels`와 `spec.template.metadata.labels`는 동일 라벨을 사용한다. Service의 `spec.selector`도 동일하게 맞춘다.

---

## 보안 컨텍스트

모든 워크로드에 적용:

```yaml
spec:
  securityContext:                    # Pod level
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - securityContext:                # Container level
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true  # 불가능하면 false + 이유 주석
        capabilities:
          drop: ["ALL"]
          # add: ["NET_BIND_SERVICE"]  # 포트 53 등 필요시만
```

예외:
- AdGuard Home: `runAsNonRoot: false` (포트 53 바인딩 필요)
- Alloy DaemonSet: hostPath 접근 필요
- 예외 적용 시 반드시 주석으로 이유를 기록한다

---

## 리소스 제한

모든 컨테이너에 requests와 limits를 명시한다.

**기준**: 피크 24시간 사용량 × 1.3

**참고 범위** (기존 앱 기준):

| 유형 | CPU req/limit | Memory req/limit |
|------|-------------|-----------------|
| 경량 서비스 (homepage, adguard) | 50m / 200m | 64Mi / 192Mi |
| 일반 웹앱 | 50m / 300m | 128Mi / 256Mi |
| 프록시/게이트웨이 (traefik) | 100m / 300m | 128Mi / 256Mi |
| 데이터베이스 (postgres) | 100m / 500m | 256Mi / 512Mi |
| 무거운 워크로드 (예: 미디어 서버, 빌드 러너) | 200m / 1000m | 512Mi / 1Gi |
| ML 워크로드 (예: 임베딩, 벡터 검색) | 100m / 2000m | 512Mi / 4Gi |

새 앱은 `일반 웹앱` 범위로 시작하고, 모니터링 데이터에 따라 조정한다.

---

## ArgoCD 패턴

### Application 정의

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app-name>
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "<wave>"    # -1, 0, 1
  finalizers:
    - resources-finalizer.argocd.argoproj.io  # cascade deletion
spec:
  project: default
  source:
    repoURL: https://github.com/ukkiee-dev/homelab.git
    targetRevision: main
    path: manifests/<layer>/<app>
  destination:
    server: https://kubernetes.default.svc
    namespace: <namespace>
  syncPolicy:
    automated:
      selfHeal: true
      prune: true
    syncOptions:
      - CreateNamespace=true
```

### Sync Wave
- **-1**: 인프라 (ArgoCD, Traefik, Cloudflared, Tailscale, Sealed Secrets, ARC, NetworkPolicy)
- **0**: 애플리케이션 (Homepage, AdGuard, Uptime Kuma, PostgreSQL, test-web)
- **1**: 모니터링 (VictoriaMetrics, Grafana, Alloy, kube-state-metrics)

### Multi-source 패턴 (Helm + Kustomize)
Traefik, Tailscale 등 Helm 차트 + 커스텀 리소스가 필요한 경우:
```yaml
spec:
  sources:
    - repoURL: https://helm.traefik.io/traefik    # Helm 차트
      chart: traefik
      targetRevision: "34.4.1"
      helm:
        valueFiles:
          - $values/manifests/infra/traefik/values.yaml
    - repoURL: https://github.com/ukkiee-dev/homelab.git   # values 참조
      targetRevision: main
      ref: values
    - repoURL: https://github.com/ukkiee-dev/homelab.git   # 추가 리소스
      targetRevision: main
      path: manifests/infra/traefik
```

---

## 네트워킹

### Public 서비스 (Cloudflare Tunnel 경유)

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: <app>
  namespace: <ns>
  annotations:
    gethomepage.dev/enabled: "true"
    gethomepage.dev/group: "Apps"
    gethomepage.dev/name: "<표시명>"
    gethomepage.dev/icon: "<아이콘>"
    gethomepage.dev/href: "https://<subdomain>.ukkiee.dev"
    gethomepage.dev/pod-selector: "app.kubernetes.io/name=<app>"
spec:
  entryPoints:
    - web                              # Cloudflare Tunnel → port 80
  routes:
    - match: Host(`<subdomain>.ukkiee.dev`)
      kind: Rule
      services:
        - name: <service>
          port: <port>
      middlewares:
        - name: security-headers
          namespace: traefik-system
        - name: gzip
          namespace: traefik-system
        - name: rate-limit
          namespace: traefik-system
```

### Internal 서비스 (Tailscale 경유)

```yaml
spec:
  entryPoints:
    - websecure                        # Tailscale → port 443
  routes:
    - match: Host(`<subdomain>.ukkiee.dev`)
      kind: Rule
      services:
        - name: <service>
          port: <port>
      middlewares:
        - name: tailscale-only
          namespace: traefik-system
        - name: security-headers
          namespace: traefik-system
        - name: gzip
          namespace: traefik-system
  tls:
    secretName: wildcard-ukkiee-dev-tls
```

### Traefik Middlewares (traefik-system 네임스페이스)

| 이름 | 용도 |
|------|------|
| `security-headers` | HSTS, X-Content-Type-Options, 서버 헤더 제거 등 |
| `gzip` | 응답 압축 |
| `tailscale-only` | Tailscale IP 대역만 허용 (`100.64.0.0/10`, `127.0.0.1`, `192.168.192.0/20`) |
| `rate-limit` | 50 req/min avg, 100 burst, CF-Connecting-IP 기반 |
| `traefik-auth` | Traefik 대시보드 BasicAuth |

### NetworkPolicy 패턴

`apps` 네임스페이스는 default-deny 적용 후 필요한 트래픽만 허용:
- `apps-default-deny.yaml` — 기본 차단 (DNS만 허용)
- `apps-allow-traefik.yaml` — Traefik에서 앱 포트로 인입
- `apps-allow-dns.yaml` — CoreDNS 접근
- `apps-allow-kube-api.yaml` — API server 접근

새 앱 추가 시 기존 allow 정책으로 커버되는지 확인하고, 부족하면 새 NetworkPolicy를 추가한다.

---

## SealedSecrets

- **Bitnami Sealed Secrets** (kube-system 네임스페이스)
- plain-text `secret.yaml`은 `.gitignore`에 등록
- SealedSecret만 Git에 커밋

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: <app>-secrets
  namespace: <ns>
spec:
  encryptedData:
    KEY_NAME: <base64-encrypted-value>
  template:
    metadata:
      name: <app>-secrets
      namespace: <ns>
    type: Opaque
```

seal 도구: `scripts/seal-secret.sh set <ns> <secret> <key> [value]`

---

## 모니터링 통합

새 워크로드에 메트릭 엔드포인트가 있으면:
```yaml
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "<metrics-port>"
    prometheus.io/path: "/metrics"     # 기본 /metrics가 아닌 경우
```

Health check probe는 모든 Deployment에 필수:
```yaml
livenessProbe:
  httpGet:
    path: /health
    port: <port>
  initialDelaySeconds: 10
  periodSeconds: 30
readinessProbe:
  httpGet:
    path: /health
    port: <port>
  initialDelaySeconds: 5
  periodSeconds: 10
```

---

## 네임스페이스 전략

| 네임스페이스 | 용도 | 앱 |
|-------------|------|-----|
| `argocd` | GitOps 컨트롤러 | ArgoCD |
| `traefik-system` | Ingress 프록시 | Traefik |
| `tailscale-system` | VPN 오퍼레이터 | Tailscale |
| `kube-system` | 시스템 컴포넌트 | Sealed Secrets |
| `networking` | 네트워크 인프라 | Cloudflared |
| `actions-runner-system` | CI/CD | ARC Runner |
| `monitoring` | 관측성 스택 | VictoriaMetrics, Grafana, Alloy 등 |
| `apps` | 일반 애플리케이션 (공유) | Homepage, AdGuard, Uptime Kuma, PostgreSQL |
| `test-web` | CI/CD 테스트 앱 전용 | test-web (setup-app 자동 생성) |

복합 서비스(컴포넌트 3개 이상)는 전용 네임스페이스를 사용하고, 단순 서비스는 `apps` 네임스페이스를 공유한다.
