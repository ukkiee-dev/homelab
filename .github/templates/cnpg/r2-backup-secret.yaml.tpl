apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: r2-pg-backup
  namespace: __APP__
stringData:
  ACCESS_KEY_ID: __R2_ACCESS_KEY_ID__
  SECRET_ACCESS_KEY: __R2_SECRET_ACCESS_KEY__
