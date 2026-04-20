# R2 Bucket for PostgreSQL offsite backups
# - Local PVC backup: /Volumes/ukkiee/homelab/backups/postgresql/ (외장 SSD, K8s CronJob이 직접 기록)
# - R2 offsite: 이 파일로 관리. 계층형 보존 (daily 7d / weekly 28d / monthly 180d)
# - CronJob이 rclone으로 prefix별 업로드 (daily/, weekly/, monthly/)

resource "cloudflare_r2_bucket" "postgresql_backup" {
  account_id    = var.account_id
  name          = "homelab-postgresql-backup"
  location      = "apac"     # 한국 기준 최적 (Seoul/Japan region)
  storage_class = "Standard" # 빈번 접근용 (복구 시 다운로드 비용 부담 최소화)
  # jurisdiction 기본값 "default" — 명시 불필요
}

# --- CNPG (CloudNativePG) 백업 버킷 (Phase 4, 2026-04) ---
#
# 신규 bucket 네이밍 `homelab-db-backups` 는 multi-engine 포괄 (향후 redis/mysql dump 도 공용).
# CNPG barman-cloud plugin 이 `<cluster-name>/base/` + `<cluster-name>/wals/` prefix 로 업로드.
# retentionPolicy 는 ObjectStore CR spec 에서 관리 (barman 자체 로직), R2 lifecycle 추가 안 함.
#
# R2 Bucket Lock (prefix 기반 retention) 은 Phase 9 안정화 이후 별도 이니셔티브로 연기:
#   - barman-cloud 호환성 미검증 (충돌 시 backup-delete 차단 → 운영 장애 가능)
#   - R14 완화선은 design §16 외장 SSD mirror + archive-YYYYMMDD prefix 로 대체
resource "cloudflare_r2_bucket" "db_backups" {
  account_id    = var.account_id
  name          = "homelab-db-backups"
  location      = "apac"
  storage_class = "Standard"
}

resource "cloudflare_r2_bucket_lifecycle" "postgresql_backup" {
  account_id  = var.account_id
  bucket_name = cloudflare_r2_bucket.postgresql_backup.name

  # NOTE: rule 순서는 Cloudflare R2 API 가 id 알파벳 오름차순으로 반환하는 것에 맞춤.
  # 논리적 순서(daily→weekly→monthly)로 두면 매 terraform plan 마다 drift 로 잡혀 false positive.
  # 세 rule 은 prefix 가 서로 독립이라 평가 순서는 동작에 영향 없음.
  rules = [
    # daily/ prefix — 7일 후 자동 삭제 (7 * 86400 = 604800초)
    {
      id      = "expire-daily-7d"
      enabled = true
      conditions = {
        prefix = "daily/"
      }
      delete_objects_transition = {
        condition = {
          type    = "Age"
          max_age = 604800
        }
      }
    },
    # monthly/ prefix — 180일 후 자동 삭제 (180 * 86400 = 15552000초)
    {
      id      = "expire-monthly-180d"
      enabled = true
      conditions = {
        prefix = "monthly/"
      }
      delete_objects_transition = {
        condition = {
          type    = "Age"
          max_age = 15552000
        }
      }
    },
    # weekly/ prefix — 28일 후 자동 삭제 (28 * 86400 = 2419200초)
    {
      id      = "expire-weekly-28d"
      enabled = true
      conditions = {
        prefix = "weekly/"
      }
      delete_objects_transition = {
        condition = {
          type    = "Age"
          max_age = 2419200
        }
      }
    }
  ]
}
