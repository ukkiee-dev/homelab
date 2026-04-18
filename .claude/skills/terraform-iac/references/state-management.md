# 상태 관리 레퍼런스

상태 관리자가 R2 백엔드 상태 파일을 관리할 때 참조하는 가이드.

## 목차

1. [R2 백엔드 상세](#r2-백엔드-상세)
2. [State Locking 부재와 대응](#state-locking-부재와-대응)
3. [상태 진단 절차](#상태-진단-절차)
4. [Import 워크플로우](#import-워크플로우)
5. [State 마이그레이션](#state-마이그레이션)
6. [백업과 복구](#백업과-복구)

---

## R2 백엔드 상세

### 설정

```hcl
backend "s3" {
  bucket                      = "ukkiee-terraform-state"
  key                         = "homelab/terraform.tfstate"
  region                      = "auto"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
  use_path_style              = true
}
```

### Init 시 주입되는 값

```bash
terraform init \
  -backend-config="endpoint=https://{account_id}.r2.cloudflarestorage.com" \
  -backend-config="access_key={R2_ACCESS_KEY_ID}" \
  -backend-config="secret_key={R2_SECRET_ACCESS_KEY}"
```

CI에서는 GitHub Secrets에서 주입. 로컬 실행 시 환경변수 또는 `-backend-config` 필요.

### R2 vs S3 차이

R2는 S3 호환 API를 제공하지만 완전한 호환은 아니다:
- DynamoDB 잠금 미지원 → state locking 없음
- S3 버저닝 미지원 → 자동 state 히스토리 없음
- 모든 S3 검증 스킵 필수 (skip_* 플래그 4개)

## State Locking 부재와 대응

### 문제

동시에 두 Terraform 프로세스가 state를 수정하면 state 파일이 손상될 수 있다.

### 현재 완화책

1. **GHA concurrency group**: `homelab-terraform` 그룹으로 워크플로우 직렬화
   ```yaml
   concurrency:
     group: homelab-terraform
     cancel-in-progress: false
   ```
2. **로컬 실행 제한**: apply는 CI에서만 실행하는 관행

### 안전 수칙

- 로컬에서 state 수정 명령(import, state rm, state mv) 실행 전 GHA 워크플로우가 실행 중이 아닌지 확인
- `gh run list --workflow=teardown.yml --status=in_progress`로 확인 가능
- 동시 접근이 의심되면 `terraform state pull`로 현재 state를 로컬에 백업 후 진행

## 상태 진단 절차

### 1. 리소스 목록 확인

```bash
terraform state list
```

예상 출력:
```
cloudflare_record.apps["argocd"]
cloudflare_record.apps["test-web"]
```

apps.json의 키 수와 state list의 리소스 수가 일치해야 함.

### 2. 개별 리소스 상세

```bash
terraform state show 'cloudflare_record.apps["argocd"]'
```

주요 확인 항목:
- `name` = apps.json의 subdomain 값
- `type` = "CNAME"
- `content` = `{tunnel_id}.cfargotunnel.com`
- `proxied` = true

### 3. State-인프라 동기화 확인

```bash
terraform plan
```

`No changes` 출력이 이상적. 차이가 있으면 드리프트 분석 필요.

## Import 워크플로우

기존 Cloudflare DNS 레코드를 Terraform state에 추가하는 절차.

### 1. 레코드 ID 조회

Cloudflare API로 조회:
```bash
curl -s -X GET "https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records?name={subdomain}.ukkiee.dev" \
  -H "Authorization: Bearer {api_token}" | jq '.result[0].id'
```

### 2. Import 실행

```bash
terraform import 'cloudflare_record.apps["{app-name}"]' {zone_id}/{record_id}
```

### 3. 검증

```bash
terraform plan
# "No changes" 확인. 차이가 있으면 dns.tf 또는 apps.json 조정 필요.
```

### 주의사항

- Import 전 apps.json에 해당 앱 항목이 있어야 함 (for_each의 키로 사용)
- Import 주소의 key는 앱 이름 (서브도메인이 아님)
- Import 후 plan에서 차이가 나면 코드를 실제 상태에 맞게 조정

## State 마이그레이션

### State Move (리소스 주소 변경)

리팩토링으로 리소스 주소가 변경될 때 사용. destroy+recreate를 방지.

```bash
# 단일 리소스 이동
terraform state mv 'cloudflare_record.apps["old-name"]' 'cloudflare_record.apps["new-name"]'

# 모듈 간 이동
terraform state mv 'module.old.resource' 'module.new.resource'
```

### State Remove (관리 해제)

Terraform 관리에서 제외하되 실제 인프라는 유지.

```bash
# 백업 먼저
terraform state pull > backup_$(date +%Y%m%d_%H%M%S).tfstate

# 제거
terraform state rm 'cloudflare_record.apps["app-name"]'
```

### 백엔드 마이그레이션

R2에서 다른 백엔드로 이동 시:

1. `backend.tf`에서 backend 블록 변경
2. `terraform init -migrate-state` 실행
3. 마이그레이션 확인 프롬프트에 `yes`

## 백업과 복구

### 수동 백업

```bash
terraform state pull > backup_$(date +%Y%m%d_%H%M%S).tfstate
```

### 복구

```bash
terraform state push backup_20260401_120000.tfstate
```

R2에 버저닝이 없으므로, 파괴적 작업 전 반드시 수동 백업을 수행한다.

### 백업 권장 시점

- state rm 실행 전
- state mv 실행 전
- force-unlock 실행 전
- 백엔드 마이그레이션 전
- provider 메이저 업그레이드 전
