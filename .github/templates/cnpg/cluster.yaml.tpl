apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: __APP__-pg
  namespace: __APP__
  annotations:
    argocd.argoproj.io/sync-wave: "0"
  labels:
    app.kubernetes.io/name: __APP__-pg
    app.kubernetes.io/component: database
    app.kubernetes.io/part-of: __APP__
    app.kubernetes.io/managed-by: argocd
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:__PG_IMAGE_TAG__
  primaryUpdateStrategy: unsupervised

  storage:
    size: __STORAGE__
    storageClass: local-path

  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

  monitoring:
    enablePodMonitor: false

  # VM kubernetes-pods auto-discovery 용 annotation
  inheritedMetadata:
    annotations:
      prometheus.io/scrape: "true"
      prometheus.io/port: "9187"
      prometheus.io/path: "/metrics"

  # Phase 5 알람 4종 전제 GUC + slow query 관측
  postgresql:
    parameters:
      shared_buffers: "128MB"
      work_mem: "4MB"
      max_connections: "50"
      maintenance_work_mem: "32MB"
      effective_cache_size: "256MB"
      wal_buffers: "8MB"
      log_min_duration_statement: "250ms"
      log_checkpoints: "on"

  # managed.roles 는 composite action 이 yq 로 병합 (owner 1개 이상)
  managed:
    roles: []

  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: __APP__-backup
        serverName: __APP__-pg
