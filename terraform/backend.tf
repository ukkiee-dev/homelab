terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.18.0"
    }
  }

  backend "s3" {
    bucket = "ukkiee-terraform-state"
    key    = "homelab/terraform.tfstate"
    region = "auto"

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
    # endpoint는 terraform init -backend-config으로 주입
  }
}
