apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: __DB_NAME__
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
