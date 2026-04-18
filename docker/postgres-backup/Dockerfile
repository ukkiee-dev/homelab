FROM postgres:18-alpine

# renovate: datasource=github-releases depName=rclone/rclone extractVersion=^v(?<version>.+)$
# NOTE: rclone CLI는 `RCLONE_*` 환경변수를 자기 자신의 flag로 해석한다
# (예: RCLONE_VERSION → --version). ARG 이름에 `RCLONE_` prefix 사용 금지.
# 이 ARG는 Docker가 RUN 단계에서 env로 export하므로 이름이 rclone flag와
# 겹치면 `rclone version` 검증 시 "invalid argument" 에러 발생.
ARG RCLONE_V=1.69.0

RUN set -eux; \
    apk add --no-cache --virtual .fetch-deps curl unzip ca-certificates; \
    ARCH=$(uname -m); \
    case "$ARCH" in \
      aarch64|arm64) RC_ARCH=arm64 ;; \
      x86_64|amd64)  RC_ARCH=amd64 ;; \
      *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://downloads.rclone.org/v${RCLONE_V}/rclone-v${RCLONE_V}-linux-${RC_ARCH}.zip" -o /tmp/rclone.zip; \
    unzip -q /tmp/rclone.zip -d /tmp/; \
    install -m 755 "/tmp/rclone-v${RCLONE_V}-linux-${RC_ARCH}/rclone" /usr/local/bin/rclone; \
    rm -rf /tmp/rclone.zip "/tmp/rclone-v${RCLONE_V}-linux-${RC_ARCH}"; \
    apk del .fetch-deps; \
    rclone version; \
    pg_dump --version

LABEL org.opencontainers.image.source="https://github.com/ukkiee-dev/homelab"
LABEL org.opencontainers.image.description="PostgreSQL client (pg_dump/pg_restore) + rclone preinstalled for homelab backup CronJob"
LABEL org.opencontainers.image.licenses="PostgreSQL AND MIT"
