FROM alpine:3.23

# Install dependencies
# Note: postgresql-client and mariadb-client are NOT needed here because backups
# run inside the target containers via 'docker exec', not from this sidecar container
RUN apk add --no-cache \
    aws-cli \
    bash \
    coreutils \
    dcron \
    docker-cli \
    docker-cli-compose \
    tzdata \
    util-linux \
    zstd

# Copy scripts
COPY --chmod=755 backup.sh /usr/local/bin/backup.sh
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
