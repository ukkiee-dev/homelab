variable "cloudflare_api_token" {
  description = "Cloudflare API Token (Zone:DNS Edit, Firewall Services Edit, Tunnel Edit)"
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
  description = "Trusted IP address for WAF allow rule (optional)"
  type        = string
  default     = ""
}
