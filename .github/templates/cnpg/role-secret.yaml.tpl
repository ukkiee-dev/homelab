apiVersion: v1
kind: Secret
type: kubernetes.io/basic-auth
metadata:
  name: __APP__-pg-__ROLE_NAME__-credentials
  namespace: __APP__
  labels:
    cnpg.io/reload: "true"
stringData:
  username: __ROLE_NAME__
  password: __PASSWORD__
