# 앱 폐기 플레이북

decommission-manager가 앱 제거 시 참조하는 상세 절차.

## 1. 표준 앱 제거 (teardown 워크플로우)

`apps.json`에 등록된 표준 앱은 teardown 워크플로우로 자동 제거 가능.

### 사전 조건 확인
- apps.json에 해당 앱이 존재하는지 확인
- PVC 데이터가 있다면 백업 완료 확인
- 의존성 분석 완료

### 트리거 방법
```bash
gh workflow run teardown.yml \
  -f app-name={app-name} \
  -f subdomain={subdomain}  # 선택, 미입력 시 apps.json에서 자동 조회
```

### teardown 워크플로우 실행 순서
1. apps.json에서 앱 엔트리 제거
2. Terraform apply (DNS CNAME 삭제)
3. Cloudflare Tunnel ingress 제거 (API)
4. GHCR 패키지 삭제
5. `manifests/apps/{app}/` 디렉토리 삭제
6. `argocd/applications/apps/{app}.yaml` 삭제
7. Git commit & push
8. kubectl delete application (cascade delete)

## 2. 복잡한 앱 제거 (수동)

전용 네임스페이스, Helm 기반, 또는 multi-source ArgoCD Application은 수동 제거.

### 순서
1. **데이터 백업** (PVC 있는 경우)
   ```bash
   # PVC 데이터 확인
   kubectl exec -n {ns} {pod} -- du -sh /data
   # 백업 (예시)
   kubectl cp {ns}/{pod}:/data ./backup-{app}-$(date +%Y%m%d)
   ```

2. **ArgoCD Application 삭제**
   ```bash
   # cascade delete (하위 리소스 모두 제거)
   kubectl delete application {app} -n argocd
   # finalizer가 완료될 때까지 대기
   kubectl wait --for=delete application/{app} -n argocd --timeout=120s
   ```

3. **Git에서 매니페스트 제거**
   ```
   rm -rf manifests/{layer}/{app}/
   rm -f argocd/applications/{layer}/{app}.yaml
   ```

4. **apps.json에서 제거** (해당 시)
   ```bash
   jq --arg name "{app}" 'del(.[$name])' terraform/apps.json > /tmp/apps.json
   mv /tmp/apps.json terraform/apps.json
   ```

5. **Tunnel ingress 제거** (해당 시)
   ```bash
   bash .github/scripts/manage-tunnel-ingress.sh remove "{subdomain}.ukkiee.dev"
   ```

6. **네임스페이스 정리** (전용 네임스페이스인 경우)
   ```bash
   # ArgoCD가 cascade delete를 하므로 보통 자동 정리됨
   # 잔여 리소스 확인
   kubectl get all -n {ns}
   # 네임스페이스 삭제 (비어있을 때만)
   kubectl delete namespace {ns}
   ```

7. **Git commit & push**

## 3. 의존성 분석 패턴

### 직접 의존
```bash
# 다른 앱의 환경변수에서 이 앱 참조
grep -r "{app-name}" manifests/ --include="*.yaml" \
  | grep -v "manifests/apps/{app-name}/" \
  | grep -v "kustomization.yaml"

# 다른 앱의 IngressRoute에서 이 서비스 참조
grep -r "name: {app-name}" manifests/ --include="ingressroute.yaml" \
  | grep -v "manifests/apps/{app-name}/"
```

### 간접 의존
- Homepage 대시보드: `gethomepage.dev/href` annotation에서 이 앱 URL 참조
- 모니터링: Grafana 대시보드에서 이 앱 메트릭 쿼리
- 알림: Grafana 알림 규칙에서 이 앱 대상

### 공통 의존 패턴
| 패턴 | 예시 | 확인 방법 |
|------|------|----------|
| DB 의존 | 앱 → PostgreSQL | 앱의 DB_URL 환경변수 |
| API 의존 | 프론트엔드 → 백엔드 API | 앱의 API_URL 환경변수 |
| 인증 의존 | 앱 → OAuth 프로바이더 | 앱의 AUTH_URL 환경변수 |
| 스토리지 공유 | 여러 앱 → 같은 PVC | PVC claimName 확인 |

## 4. 되돌릴 수 없는 작업 목록

| 작업 | 영향 | 복구 방법 |
|------|------|----------|
| GHCR 패키지 삭제 | 이미지 영구 삭제 | CI에서 재빌드 |
| PVC 데이터 삭제 | 사용자 데이터 손실 | 백업에서 복원 (백업이 있을 때만) |
| SealedSecret 삭제 | 암호화 키 분실 | 원본 시크릿 재생성 + 재seal |
| DNS CNAME 삭제 | 서브도메인 접근 불가 | Terraform으로 재생성 |

## 5. 폐기 후 검증

```bash
# ArgoCD Application 삭제 확인
kubectl get application {app} -n argocd 2>&1 | grep "not found"

# 네임스페이스 내 리소스 정리 확인
kubectl get all -n {namespace} -l app.kubernetes.io/name={app}

# DNS 전파 확인 (수 분 소요)
dig {subdomain}.ukkiee.dev +short  # 결과 없어야 함

# apps.json에서 제거 확인
jq --arg name "{app}" 'has($name)' terraform/apps.json  # false
```
