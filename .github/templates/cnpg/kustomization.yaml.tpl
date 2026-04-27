apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: __APP__

resources:
  - namespace.yaml
  # cluster-wide ghcr-pull-secret SealedSecret. setup-app/action.yml 이 파일은
  # common/ 에 복사하지만 본 database template kustomization 이 후행 덮어쓰기를
  # 하므로 여기에도 명시 (선결 PR ukkiee-dev/homelab#41 에서 pokopia-wiki 만 수동
  # fix 한 것을 정석화).
  - ghcr-pull-secret.sealed.yaml
  - role-secrets.sealed.yaml
  - r2-backup.sealed.yaml
  - cluster.yaml
  - objectstore.yaml
  - scheduled-backup.yaml
  - network-policy.yaml
  # 시나리오-1 (공유 DB): database-shared.yaml. 시나리오-2 (분리) 또는 Phase 7 후속에서 services/<svc>/database.yaml 패턴 사용.
  - database-shared.yaml
