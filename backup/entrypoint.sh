#!/bin/sh
set -e

CRON_SCHEDULE="${CRON_SCHEDULE:-0 2 * * *}"
CRON_JOB="${CRON_SCHEDULE} /usr/local/bin/backup.sh > /proc/1/fd/1 2>/proc/1/fd/2"

echo "Configuring cron schedule: ${CRON_SCHEDULE}"
printf '%s\n' "$CRON_JOB" | crontab -

# Start crond in background mode and keep container alive
crond -b -l 2

# Keep container running indefinitely (tail -f /dev/null is a common pattern for this)
exec tail -f /dev/null
