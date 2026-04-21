# arc-runners — 배포 보류 (2026-04-22 결정)

**현재 상태**: namespace + NetworkPolicy 만 배포. **Helm chart (runner scale set) 는 미설치**. GitHub-hosted runner 만 사용 중.

## 배경

이 디렉토리는 [Actions Runner Controller (ARC)](https://github.com/actions/actions-runner-controller) in-cluster runner 도입용 placeholder 로 2026-03 경 `docs/plans/2026-04-20-cloudnativepg-migration-design.md` Phase 7 설계 시 예약되었다. 설계 의도는 homelab 내부 K8s API / ArgoCD Service 에 kubeconfig 로 직접 접근하는 워크플로우 (예: `setup-app/database` composite 의 kubeseal online 모드, `_teardown.yml` 의 ArgoCD Application DELETE) 를 지원하는 것.

## 왜 설치 안 했나

2026-04-22 후속 2 세션에서 GitHub-hosted runner 의 제약을 **GitOps 로 우회**하는 두 건의 구조 전환이 완료됨:

| PR | 전환 | 해소한 ARC 필요성 |
|----|------|------------------|
| #34 | `kubeseal --controller-*` → `--cert <path>` offline 모드 | SealedSecret 생성에 kubeconfig 불필요 |
| #35 | `argocd/root.yaml` prune: `false → true` + teardown Step 3.5 제거 | Application 삭제에 ArgoCD API 호출 불필요 (git + finalizer cascade) |

즉 **현재 시점에는 ARC 의 주요 사용처가 사실상 없다**. GitHub-hosted runner 로 모든 create-app/teardown/add-database 자동화가 동작한다 (`ukkiee-dev/test-phase3b` E2E 검증 통과, 2026-04-22).

## 남는 이론적 시나리오 (미래 재검토 트리거)

ARC 를 실제 설치해야 할 수 있는 경우:

1. **GitHub Actions 무료 분 초과** — public 무제한, private 2000 분/월. 홈랩 트래픽으로는 초과 가능성 낮음
2. **6 시간 초과 장시간 job** — 현재 워크플로우 중 가장 오래 걸리는 create-app 도 5 분 미만
3. **GitHub-hosted 에 비해 큰 캐시/네트워크 이점이 필요한 in-cluster build** — Docker buildx 가 로컬 BuildKit 재사용 필요한 경우. 현재 build.yml 은 GHA 매트릭스로 충분
4. **기밀/정책상 외부 runner 사용 불가** — 개인 홈랩 특성상 해당 사항 없음

위 중 하나라도 현실이 되면 이 문서를 갱신하고 Helm install 절차를 실행한다.

## 설치하려면 (참고 — 현재 실행 금지)

배포 시점의 대략적 절차:

```bash
# 1. GitHub App 설치 (ukkiee-dev 조직 전체 권한 또는 선택 레포)
#    App ID + installation ID + private key 수집

# 2. Installation 크레덴셜을 SealedSecret 으로 생성
cat <<EOF | kubeseal --cert manifests/infra/sealed-secrets/controller-cert.pem \
  --namespace actions-runner-system --name arc-runner-credentials \
  --format=yaml > manifests/infra/arc-runners/runner-credentials.sealed.yaml
apiVersion: v1
kind: Secret
metadata:
  name: arc-runner-credentials
  namespace: actions-runner-system
stringData:
  github_app_id: "<ID>"
  github_app_installation_id: "<INSTALLATION_ID>"
  github_app_private_key: |
    -----BEGIN RSA PRIVATE KEY-----
    ...
EOF

# 3. Controller (cluster-wide) helm install
helm install arc-controller \
  --namespace actions-runner-system \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  -f manifests/infra/arc-runners/values-controller.yaml

# 4. Runner scale set helm install (githubConfigSecret 은 위 SealedSecret 이름 참조로 수정)
helm install arc-runner-set \
  --namespace actions-runner-system \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  -f manifests/infra/arc-runners/values-runner.yaml

# 5. 각 워크플로우에 runs-on: self-hosted 로 전환 시점 결정 (점진 roll-in)
```

설치 시 `values-runner.yaml` 의 `githubConfigSecret.github_token: ""` placeholder 를 **GitHub App secret 이름으로 교체** 해야 한다 (또는 values 를 App id/installation id/private key 블록으로 변경).

## 관련 링크

- 결정 memo: `~/.claude/projects/-Users-ukyi-homelab/memory/project_arc_deprioritize_2026_04_22.md`
- GitOps 대체 근거: `~/.claude/projects/-Users-ukyi-homelab/memory/project_gha_runner_cluster_access.md`
- 원래 설계: `docs/plans/2026-04-20-cloudnativepg-migration-design.md` §D10 (ARC runner in-cluster kubeseal 설계)
