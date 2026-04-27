apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  # K8s metadata.name 은 RFC 1123 (소문자 영숫자 + - + .) 강제 — underscore 금지.
  # action.yml 이 __DB_NAME__ 을 sanitize (`_` → `-`) 후 `-db` 접미사 부여 → __DB_K8S_NAME__.
  # spec.name (실제 PG database 이름) 은 PG 표준 underscore 유지.
  name: __DB_K8S_NAME__
  namespace: __APP__
  annotations:
    # Cluster (wave 0) + managed.roles reconcile 후 Database
    argocd.argoproj.io/sync-wave: "1"
spec:
  cluster:
    name: __APP__-pg
  name: __DB_NAME__
  owner: __ROLE_NAME__
  # v0.4 I-2a: ArgoCD prune 방어, 기본값 명시적 박제
  databaseReclaimPolicy: retain
