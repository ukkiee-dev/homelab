# PostgreSQL Helm Upgrade Runbook

> Bitnami `postgresql` chart를 upgrade할 때 필수로 거쳐야 할 절차.
> `auth.existingSecret` 사용 중인 환경에서 helm이 password를 재주입해야 하므로, 실패 시 upgrade가 멈추거나 Secret을 덮어쓸 수 있다.

---

## 적용 대상

- 차트: `bitnami/postgresql`
- 네임스페이스: `apps`
- Secret 구성: `auth.existingSecret: postgresql-auth` (values.yaml 기준)
- 관리 수단: ArgoCD (Application `postgresql`)

---

## 증상 / 트리거

| 상황 | 증상 |
|------|------|
| Renovate가 chart minor bump PR 생성 | ArgoCD sync 시 `helm upgrade` 단계에서 실패 |
| 수동으로 `helm upgrade` 실행 | `Error: UPGRADE FAILED: execution error at ... password is required` |
| values.yaml 변경 후 ArgoCD sync | Pod가 `CrashLoopBackOff`로 새 비번으로 기동 시도 |

---

## 진단

### 1. 현재 Secret 상태 확인

```bash
kubectl -n apps get secret postgresql-auth -o yaml
# postgres-password, replication-password, password 키 확인
```

### 2. Helm release 기록 확인

```bash
helm history postgresql -n apps
# 이전 revision의 STATUS가 deployed인지, FAILED가 섞여 있는지 확인
```

### 3. ArgoCD Application 상태

```bash
kubectl -n argocd get application postgresql -o jsonpath='{.status.sync.status}'
kubectl -n argocd get application postgresql -o jsonpath='{.status.conditions}'
```

---

## 해결

### 옵션 A: ArgoCD 경유 (권장)

ArgoCD Application의 helm parameters에 password를 명시적으로 주입하면, 이후 sync가 멱등하게 작동한다.

1. Secret에서 비번 추출:

   ```bash
   POSTGRES_PASSWORD=$(kubectl -n apps get secret postgresql-auth -o jsonpath='{.data.postgres-password}' | base64 -d)
   REPLICATION_PASSWORD=$(kubectl -n apps get secret postgresql-auth -o jsonpath='{.data.replication-password}' | base64 -d)
   ```

2. Application에 parameters 추가 (임시 — sync 후 제거해도 됨):

   ```bash
   kubectl -n argocd patch application postgresql --type merge -p "$(cat <<EOF
   spec:
     source:
       helm:
         parameters:
           - name: global.postgresql.auth.password
             value: "$POSTGRES_PASSWORD"
           - name: global.postgresql.auth.replicationPassword
             value: "$REPLICATION_PASSWORD"
   EOF
   )"
   ```

3. Sync 트리거:

   ```bash
   argocd app sync postgresql
   ```

4. Sync 성공 후 parameters 제거 (Git 경로를 source of truth로 유지):

   ```bash
   kubectl -n argocd patch application postgresql --type json -p '[{"op":"remove","path":"/spec/source/helm/parameters"}]'
   ```

### 옵션 B: 수동 Helm upgrade (ArgoCD selfHeal off 상태)

> **주의**: ArgoCD selfHeal이 on이면 수동 helm 명령이 즉시 원복된다. 먼저 `selfHeal: false`로 바꾸거나 ArgoCD Application을 일시 삭제 후 진행.

```bash
POSTGRES_PASSWORD=$(kubectl -n apps get secret postgresql-auth -o jsonpath='{.data.postgres-password}' | base64 -d)
REPLICATION_PASSWORD=$(kubectl -n apps get secret postgresql-auth -o jsonpath='{.data.replication-password}' | base64 -d)

helm upgrade postgresql bitnami/postgresql \
  -n apps \
  --version <new-chart-version> \
  -f manifests/apps/postgresql/values.yaml \
  --set global.postgresql.auth.password="$POSTGRES_PASSWORD" \
  --set global.postgresql.auth.replicationPassword="$REPLICATION_PASSWORD"
```

---

## 검증

```bash
# 1. Pod 상태 (Running + Ready)
kubectl -n apps get pods -l app.kubernetes.io/name=postgresql

# 2. DB 접속 테스트
kubectl -n apps exec -it postgresql-0 -- psql -U postgres -c "SELECT version();"

# 3. Secret 변경 없음 확인 (기존 비번 보존)
kubectl -n apps get secret postgresql-auth -o jsonpath='{.data.postgres-password}' | base64 -d
# → 이전 값과 동일해야 함

# 4. ArgoCD Application Healthy
argocd app get postgresql
```

---

## Rollback

```bash
# 1. 이전 revision 확인
helm history postgresql -n apps

# 2. Rollback
helm rollback postgresql <prev-revision> -n apps

# 3. ArgoCD Application이 다시 drift 감지할 수 있음 — Application source도 이전 commit으로 되돌림
git revert <chart-version-bump-commit>
git push origin main
```

---

## 배경 / 근본 원인

Bitnami `postgresql` chart는 다음 로직을 가진다:

1. `auth.existingSecret`가 설정되어 있으면 Secret을 신규 생성하지 않고 참조만 함.
2. 하지만 chart rendering 중 일부 템플릿(backup CronJob, ServiceMonitor credentials 등)은 `global.postgresql.auth.password` 값을 직접 참조.
3. `helm upgrade` 시 이 값이 비어 있으면 template이 실패 → 전체 upgrade abort.
4. Secret 내용은 helm의 관리 밖이므로 chart 쪽이 직접 읽지 못함.

따라서 upgrade 시점에 **명시적으로** 비번을 `--set`으로 주입해 rendering을 성공시키고, 실제 Pod는 `auth.existingSecret` 참조로 기동되게 해야 한다.

---

## 관련 문서

- Bitnami 공식 이슈: [helm/charts#2061](https://github.com/bitnami/charts/issues/2061) (password handling)
- ArgoCD Application: `argocd/applications/apps/postgresql.yaml`
- Values: `manifests/apps/postgresql/values.yaml`
- 후속 TODO: `docs/plans/2026-04-18-grafana-followup-todo.md` P1 #3
