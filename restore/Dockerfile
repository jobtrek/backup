FROM alpine:3.22

# Install dependencies
RUN apk add --no-cache \
    aws-cli \
    bash \
    coreutils \
    docker-cli \
    docker-cli-compose \
    tzdata \
    util-linux \
    zstd

# Copy scripts
COPY --chmod=755 restore.sh /usr/local/bin/restore.sh
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
