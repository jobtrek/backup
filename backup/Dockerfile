FROM alpine:3.22

# Install dependencies
# Note: postgresql-client and mariadb-client are NOT needed here because backups
# run inside the target containers via 'docker exec', not from this sidecar container
RUN apk add --no-cache \
    bash \
    docker-cli \
    docker-cli-compose \
    zstd \
    aws-cli \
    dcron \
    util-linux \
    coreutils \
    tzdata

# Copy scripts
COPY --chmod=755 backup.sh /usr/local/bin/backup.sh
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
