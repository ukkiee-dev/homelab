# TODO: ArgoCD UI에서 인프라 앱 숨기기

## 배경

ArgoCD UI에 sealed-secrets, tailscale-operator, traefik 등 인프라 컴포넌트가
일반 앱과 함께 표시되고 있어 시각적 노이즈가 됨.
이들은 한번 배포하면 거의 변경되지 않는 인프라 레벨 앱이므로 UI에서 분리하는 것이 좋음.

## 대상 앱

| 앱 | 네임스페이스 | Application YAML |
|---|---|---|
| sealed-secrets | kube-system | `argocd/applications/infra/sealed-secrets.yaml` |
| tailscale-operator | tailscale-system | `argocd/applications/infra/tailscale-operator.yaml` |
| traefik | traefik-system | `argocd/applications/infra/traefik.yaml` |

## 방법 검토

### 방법 1: ArgoCD Project 분리 (권장)

인프라 전용 `infra` 프로젝트를 만들고, 해당 앱들을 `project: infra`로 변경.
UI에서 프로젝트 필터로 `default`만 보면 인프라 앱이 숨겨짐.

```yaml
# manifests/infra/argocd/appproject-infra.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: infra
  namespace: argocd
spec:
  description: Infrastructure components (low-visibility)
  sourceRepos:
    - '*'
  destinations:
    - namespace: '*'
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
```

각 앱의 `spec.project`를 `default` -> `infra`로 변경.

**장점**: GitOps 유지, 권한 분리 가능, UI 필터링 자연스러움
**단점**: AppProject 리소스 추가 필요

### 방법 2: 레이블 기반 UI 필터링

이미 `app.kubernetes.io/part-of: homelab` 레이블이 있음.
`tier: infra` / `tier: app` 레이블을 추가하고 UI에서 필터링.

```yaml
metadata:
  labels:
    tier: infra  # 또는 tier: app
```

**장점**: 변경 최소, 기존 구조 유지
**단점**: UI에서 매번 필터 설정 필요 (저장 안 됨)

### 방법 3: ArgoCD Server 설정으로 기본 필터 적용

`argocd-cmd-params-cm` ConfigMap에서 기본 필터를 설정할 수 있음.

**장점**: 접속 시 자동 필터링
**단점**: 설정 복잡, ArgoCD 버전 의존적

## 추천

**방법 1 (Project 분리)** 이 가장 깔끔함.
- `infra` 프로젝트로 인프라 앱 격리
- 필요 시 `infra` 프로젝트에 별도 RBAC 적용 가능
- ArgoCD UI에서 프로젝트 필터는 URL에 저장되어 북마크 가능

## 작업 순서

1. `AppProject` 리소스 `infra` 생성
2. sealed-secrets, tailscale-operator, traefik의 `spec.project`를 `infra`로 변경
3. ArgoCD sync 확인
4. 필요시 arc-runners, cloudflared, network-policies도 `infra` 프로젝트로 이동 검토
