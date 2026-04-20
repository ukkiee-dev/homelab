apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: __APP__-backup
  namespace: __APP__
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  configuration:
    # s3://homelab-db-backups/<app>/<cluster>/{base,wals}
    destinationPath: s3://homelab-db-backups/__APP__
    endpointURL: https://__R2_ACCOUNT_ID__.r2.cloudflarestorage.com
    s3Credentials:
      accessKeyId:
        name: r2-pg-backup
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: r2-pg-backup
        key: SECRET_ACCESS_KEY
    wal:
      compression: gzip
    data:
      compression: gzip
  retentionPolicy: "14d"
