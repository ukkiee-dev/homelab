# Security response headers are managed by Traefik middleware (security-headers)
# as the single source of truth. This covers both Cloudflare Tunnel and Tailscale access.
# Removed: cloudflare_ruleset "security_headers" (duplicate of Traefik middleware,
# X-Frame-Options SAMEORIGIN vs Traefik DENY 충돌 해소)
