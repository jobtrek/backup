FROM alpine:3.22

# Install dependencies
RUN apk add --no-cache \
    bash \
    docker-cli \
    zstd \
    aws-cli \
    util-linux \
    coreutils

# Copy scripts
COPY --chmod=755 restore.sh /usr/local/bin/restore.sh
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
