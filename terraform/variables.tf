variable "cloudflare_api_token" {
  description = "Cloudflare API Token (Zone: DNS Edit, Zone WAF Edit, Cache Rules Edit, Transform Rules Edit, Account: Cloudflare Tunnel Edit)"
  sensitive   = true
}

variable "zone_id" {
  description = "ukkiee.dev Cloudflare Zone ID"
  sensitive   = true
}

variable "tunnel_id" {
  description = "cloudflared Tunnel ID"
}

variable "account_id" {
  description = "Cloudflare Account ID"
}

variable "domain" {
  description = "Base domain for apps"
  default     = "ukkiee.dev"
}

variable "trusted_ip" {
  description = "Trusted IP/CIDR for WAF allow rule (e.g. 1.2.3.4 or 1.2.3.0/24, optional)"
  type        = string
  default     = ""
}
