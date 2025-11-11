#!/bin/bash
set -e
set -o pipefail

# --- Logging Functions ---
log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

# --- Helper Functions ---

# Wait for PostgreSQL to be ready
wait_for_postgres() {
  local container_id="$1"
  local pguser="$2"
  local timeout="${3:-60}"
  local wait_count=0
  
  log_info "  -> Waiting for PostgreSQL to be ready (timeout: ${timeout}s)..."
  
  while [[ $wait_count -lt $timeout ]]; do
    if docker exec "$container_id" pg_isready -U "$pguser" >/dev/null 2>&1; then
      log_info "  -> ✓ PostgreSQL is ready"
      return 0
    fi
    sleep 1
    wait_count=$((wait_count + 1))
  done
  
  log_warn "  -> Timeout waiting for PostgreSQL to be ready"
  return 1
}

# Wait for MariaDB to be ready
wait_for_mariadb() {
  local container_id="$1"
  local db_user="$2"
  local db_password="$3"
  local timeout="${4:-60}"
  local wait_count=0
  
  log_info "  -> Waiting for MariaDB to be ready (timeout: ${timeout}s)..."
  
  while [[ $wait_count -lt $timeout ]]; do
    if [[ -n "$db_password" ]]; then
      if docker exec "$container_id" sh -c "mysqladmin ping -u \"$db_user\" -p\"$db_password\"" >/dev/null 2>&1; then
        log_info "  -> ✓ MariaDB is ready"
        return 0
      fi
    else
      if docker exec "$container_id" sh -c "mysqladmin ping -u \"$db_user\"" >/dev/null 2>&1; then
        log_info "  -> ✓ MariaDB is ready"
        return 0
      fi
    fi
    sleep 1
    wait_count=$((wait_count + 1))
  done
  
  log_warn "  -> Timeout waiting for MariaDB to be ready"
  return 1
}

# --- Configuration (from Environment Variables) ---
: "${PROJECT_NAME?Missing PROJECT_NAME env var}"
: "${S3_BUCKET_URL?Missing S3_BUCKET_URL env var}"
: "${AWS_ACCESS_KEY_ID?Missing AWS_ACCESS_KEY_ID env var}"
: "${AWS_SECRET_ACCESS_KEY?Missing AWS_SECRET_ACCESS_KEY env var}"
: "${AWS_DEFAULT_REGION?Missing AWS_DEFAULT_REGION env var}"

# Optional parameters
RESTORE_MODE="${RESTORE_MODE:-latest}"
SKIP_STOP="${SKIP_STOP:-false}"
SKIP_START="${SKIP_START:-false}"

# Temporary directory (will be cleaned up on exit)
TEMP_DIR=$(mktemp -d)

# Cleanup function
cleanup() {
  local exit_code=$?
  if [[ -d "$TEMP_DIR" ]]; then
    log_info "Cleaning up temporary files: $TEMP_DIR"
    rm -rf "$TEMP_DIR"
  fi
  exit $exit_code
}

# Set up trap to ensure cleanup on exit
trap cleanup EXIT INT TERM

log_info "=== Restore Container Starting ==="
log_info "Project Name: ${PROJECT_NAME}"
log_info "S3 Bucket: ${S3_BUCKET_URL}"
log_info "Restore Mode: ${RESTORE_MODE}"

# --- Validation Phase ---
log_info "=== Phase 1: Validation ==="

# Check Docker socket access
if ! docker ps >/dev/null 2>&1; then
  log_error "Cannot access Docker daemon. Is /var/run/docker.sock mounted?"
  exit 1
fi
log_info "✓ Docker daemon accessible"

# Check if stack exists (by looking for containers with the project name)
STACK_CONTAINERS=$(docker ps -a --filter "label=com.docker.compose.project=${PROJECT_NAME}" --format "{{.ID}}" | wc -l)
if [[ "$STACK_CONTAINERS" -eq 0 ]]; then
  log_warn "No containers found for project '${PROJECT_NAME}'. Stack may not exist or may be using a different project name."
  log_warn "Continuing anyway as this might be a fresh restore..."
else
  log_info "✓ Found ${STACK_CONTAINERS} container(s) for stack '${PROJECT_NAME}'"
fi

# Check available disk space (require at least 5GB)
AVAILABLE_SPACE=$(df -BG "$(dirname "$TEMP_DIR")" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//' | tr -d '[:space:]')
if ! [[ "$AVAILABLE_SPACE" =~ ^[0-9]+$ ]]; then
  log_error "Could not determine available disk space"
  exit 1
fi
if [[ "$AVAILABLE_SPACE" -lt 5 ]]; then
  log_error "Insufficient disk space. Required: 5GB, Available: ${AVAILABLE_SPACE}GB"
  exit 1
fi
log_info "✓ Sufficient disk space available: ${AVAILABLE_SPACE}GB"

# --- Backup Discovery Phase ---
log_info "=== Phase 2: Backup Discovery ==="

# List all backups for this project
log_info "Listing backups in S3..."
BACKUP_PREFIX="backup_${PROJECT_NAME}_"

# Get list of backups from S3
mapfile -t AVAILABLE_BACKUPS < <(
  aws s3 ls "${S3_BUCKET_URL%/}/" 2>/dev/null | \
    grep "${BACKUP_PREFIX}" | \
    awk '{print $4}' | \
    sort -r
)

if [[ ${#AVAILABLE_BACKUPS[@]} -eq 0 ]]; then
  log_error "No backups found for project '${PROJECT_NAME}' in S3 bucket"
  exit 1
fi

log_info "Found ${#AVAILABLE_BACKUPS[@]} backup(s) for project '${PROJECT_NAME}'"

# Handle different restore modes
if [[ "$RESTORE_MODE" == "list" ]]; then
  log_info "Available backups:"
  for backup in "${AVAILABLE_BACKUPS[@]}"; do
    # Extract timestamp from filename: backup_{PROJECT_NAME}_{TIMESTAMP}_{UUID}.tar.zst
    TIMESTAMP=$(echo "$backup" | sed -E "s/backup_${PROJECT_NAME}_([0-9]{8}-[0-9]{6})_.*/\1/")
    FORMATTED_DATE=$(date -d "${TIMESTAMP:0:8} ${TIMESTAMP:9:2}:${TIMESTAMP:11:2}:${TIMESTAMP:13:2}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$TIMESTAMP")
    echo "  - $backup ($FORMATTED_DATE)"
  done
  exit 0
fi

# Select backup file
if [[ -n "$BACKUP_FILE" ]]; then
  # User specified a backup file
  SELECTED_BACKUP="$BACKUP_FILE"
  # Verify it exists
  if ! printf '%s\n' "${AVAILABLE_BACKUPS[@]}" | grep -q "^${SELECTED_BACKUP}$"; then
    log_error "Specified backup file '${BACKUP_FILE}' not found in S3"
    log_info "Available backups:"
    printf '  - %s\n' "${AVAILABLE_BACKUPS[@]}"
    exit 1
  fi
  log_info "Using specified backup: ${SELECTED_BACKUP}"
elif [[ "$RESTORE_MODE" == "latest" ]] || [[ "$RESTORE_MODE" == "specific" ]]; then
  # Select the most recent backup (first in sorted list)
  SELECTED_BACKUP="${AVAILABLE_BACKUPS[0]}"
  log_info "Using latest backup: ${SELECTED_BACKUP}"
else
  log_error "Invalid RESTORE_MODE: ${RESTORE_MODE}. Must be 'latest', 'specific', or 'list'"
  exit 1
fi

# --- Stack Shutdown Phase ---
if [[ "$SKIP_STOP" != "true" ]]; then
  log_info "=== Phase 3: Stack Shutdown ==="
  
  # Log current state
  log_info "Current stack state:"
  docker ps -a --filter "label=com.docker.compose.project=${PROJECT_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
  
  # Stop the entire stack
  log_info "Stopping stack '${PROJECT_NAME}'..."
  if docker compose --project-name "${PROJECT_NAME}" stop; then
    log_info "✓ Stack stopped successfully"
  else
    log_warn "Failed to stop stack using docker compose. Attempting to stop containers individually..."
    mapfile -t CONTAINER_IDS < <(docker ps -a --filter "label=com.docker.compose.project=${PROJECT_NAME}" --format "{{.ID}}")
    if [[ ${#CONTAINER_IDS[@]} -gt 0 ]]; then
      docker stop "${CONTAINER_IDS[@]}" || log_warn "Some containers may not have stopped cleanly"
    fi
  fi
  
  # Wait for containers to fully stop (with timeout)
  log_info "Waiting for containers to stop (timeout: 30s)..."
  WAIT_COUNT=0
  while [[ $WAIT_COUNT -lt 30 ]]; do
    RUNNING_COUNT=$(docker ps --filter "label=com.docker.compose.project=${PROJECT_NAME}" --format "{{.ID}}" | wc -l)
    if [[ "$RUNNING_COUNT" -eq 0 ]]; then
      log_info "✓ All containers stopped"
      break
    fi
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
  done
  
  if [[ $WAIT_COUNT -eq 30 ]]; then
    log_warn "Timeout waiting for containers to stop. Some containers may still be running."
  fi
else
  log_info "=== Phase 3: Stack Shutdown [SKIPPED] ==="
fi

# --- Backup Download & Extraction Phase ---
log_info "=== Phase 4: Backup Download & Extraction ==="

DOWNLOAD_PATH="${TEMP_DIR}/${SELECTED_BACKUP}"
log_info "Downloading backup from S3..."
if aws s3 cp "${S3_BUCKET_URL%/}/${SELECTED_BACKUP}" "$DOWNLOAD_PATH"; then
  DOWNLOAD_SIZE=$(stat -c%s "$DOWNLOAD_PATH" | numfmt --to=iec-i --suffix=B)
  log_info "✓ Download complete: ${DOWNLOAD_SIZE}"
else
  log_error "Failed to download backup from S3"
  exit 1
fi

# Verify archive integrity
log_info "Verifying archive integrity..."
if zstd -t "$DOWNLOAD_PATH" >/dev/null 2>&1; then
  log_info "✓ Archive integrity verified"
else
  log_error "Archive integrity check failed"
  exit 1
fi

# Extract archive
EXTRACT_DIR="${TEMP_DIR}/extracted"
mkdir -p "$EXTRACT_DIR"
log_info "Extracting archive..."
if tar -I zstd -xf "$DOWNLOAD_PATH" -C "$EXTRACT_DIR"; then
  log_info "✓ Archive extracted successfully"
  # Remove downloaded archive to save space
  rm -f "$DOWNLOAD_PATH"
else
  log_error "Failed to extract archive"
  exit 1
fi

# --- Volume Restoration Phase ---
log_info "=== Phase 5: Volume Restoration ==="

# Find all services in the backup
shopt -s nullglob
SERVICE_DIRS=("$EXTRACT_DIR"/*)
shopt -u nullglob

if [[ ${#SERVICE_DIRS[@]} -eq 0 ]]; then
  log_error "No service directories found in backup"
  exit 1
fi

log_info "Found ${#SERVICE_DIRS[@]} service(s) in backup"

# Process each service
for SERVICE_DIR in "${SERVICE_DIRS[@]}"; do
  SERVICE_NAME=$(basename "$SERVICE_DIR")
  log_info "Processing service: ${SERVICE_NAME}"
  
  # Find container for this service
  CONTAINER_ID=$(docker ps -a \
    --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
    --filter "label=com.docker.compose.service=${SERVICE_NAME}" \
    --format "{{.ID}}" | head -1)
  
  if [[ -z "$CONTAINER_ID" ]]; then
    log_warn "  -> No container found for service '${SERVICE_NAME}'. Skipping volume restoration."
    continue
  fi
  
  log_info "  -> Found container: ${CONTAINER_ID}"
  
  # Restore volumes
  if [[ -d "$SERVICE_DIR/volumes" ]]; then
    shopt -s nullglob
    VOLUME_DIRS=("$SERVICE_DIR/volumes"/*)
    shopt -u nullglob
    
    if [[ ${#VOLUME_DIRS[@]} -gt 0 ]]; then
      log_info "  -> Restoring ${#VOLUME_DIRS[@]} volume(s)"
      
      for VOLUME_DIR in "${VOLUME_DIRS[@]}"; do
        VOLUME_NAME=$(basename "$VOLUME_DIR")
        
        # Find the mount point for this volume in the container
        # We need to check labels to find the original path
        mapfile -t VOLUME_LABELS < <(
          docker inspect "$CONTAINER_ID" --format='{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' | \
          grep "^backup\.volume-path\.${VOLUME_NAME}="
        )
        
        if [[ ${#VOLUME_LABELS[@]} -eq 0 ]]; then
          log_warn "    - Volume '${VOLUME_NAME}': No label found, skipping"
          continue
        fi
        
        # Extract the path from the label
        VOLUME_PATH="${VOLUME_LABELS[0]#*=}"
        
        if [[ -z "$VOLUME_PATH" || "$VOLUME_PATH" == "<no value>" ]]; then
          log_warn "    - Volume '${VOLUME_NAME}': Invalid path, skipping"
          continue
        fi
        
        log_info "    - Restoring '${VOLUME_NAME}' to ${VOLUME_PATH}"
        
        # Clear existing content and restore
        if docker exec "$CONTAINER_ID" sh -c "rm -rf ${VOLUME_PATH}/* ${VOLUME_PATH}/.[!.]* 2>/dev/null || true" && \
           docker cp "$VOLUME_DIR/." "$CONTAINER_ID:$VOLUME_PATH/"; then
          log_info "      ✓ Restored successfully"
        else
          log_error "      ✗ Failed to restore volume"
        fi
      done
    fi
  fi
done

# --- Database Restoration Phase ---
log_info "=== Phase 6: Database Restoration ==="

# We need to start containers for database restoration
if [[ "$SKIP_STOP" != "true" ]]; then
  log_info "Starting containers for database restoration..."
  if docker compose --project-name "${PROJECT_NAME}" start; then
    log_info "✓ Containers started"
  else
    log_warn "Failed to start stack using docker compose. Attempting to start containers individually..."
    mapfile -t CONTAINER_IDS < <(docker ps -a --filter "label=com.docker.compose.project=${PROJECT_NAME}" --format "{{.ID}}")
    if [[ ${#CONTAINER_IDS[@]} -gt 0 ]]; then
      docker start "${CONTAINER_IDS[@]}" || log_warn "Some containers may not have started cleanly"
    fi
  fi
fi

# Process each service for database restoration
for SERVICE_DIR in "${SERVICE_DIRS[@]}"; do
  SERVICE_NAME=$(basename "$SERVICE_DIR")
  
  # Find container for this service
  CONTAINER_ID=$(docker ps \
    --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
    --filter "label=com.docker.compose.service=${SERVICE_NAME}" \
    --format "{{.ID}}" | head -1)
  
  if [[ -z "$CONTAINER_ID" ]]; then
    continue
  fi
  
  # Restore PostgreSQL database
  if [[ -f "$SERVICE_DIR/database/pg_dumpall.sql" ]]; then
    log_info "Restoring PostgreSQL database for service: ${SERVICE_NAME}"
    
    # Get database credentials from container
    CONTAINER_ENV=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_ID")
    PGUSER=$(echo "$CONTAINER_ENV" | grep "^POSTGRES_USER=" | cut -d= -f2- || true)
    PGPASSWORD=$(echo "$CONTAINER_ENV" | grep "^POSTGRES_PASSWORD=" | cut -d= -f2- || true)
    PGUSER="${PGUSER:-postgres}"
    
    if [[ -z "$PGPASSWORD" || "$PGPASSWORD" == "<no value>" ]]; then
      PGPASSWORD_FILE=$(echo "$CONTAINER_ENV" | grep "^POSTGRES_PASSWORD_FILE=" | cut -d= -f2- || true)
      if [[ -n "$PGPASSWORD_FILE" && "$PGPASSWORD_FILE" != "<no value>" ]]; then
        PGPASSWORD=$(docker exec "$CONTAINER_ID" cat "$PGPASSWORD_FILE" 2>/dev/null || true)
      fi
    fi
    
    # Wait for PostgreSQL to be ready
    wait_for_postgres "$CONTAINER_ID" "$PGUSER"
    
    if [[ -n "$PGPASSWORD" ]]; then
      # Create .pgpass file for authentication
      docker exec "$CONTAINER_ID" sh -c 'printf "*:*:*:%s:%s\n" "$1" "$2" > /tmp/.pgpass && chmod 600 /tmp/.pgpass' sh "$PGUSER" "$PGPASSWORD"
      
      # Restore database
      RESTORE_EXIT_CODE=0
      if docker exec -i \
        --env "PGPASSFILE=/tmp/.pgpass" \
        "$CONTAINER_ID" sh -c "psql -U \"$PGUSER\" -d postgres" \
        < "$SERVICE_DIR/database/pg_dumpall.sql" 2>&1 | tee "$TEMP_DIR/restore_pg.log"; then
        RESTORE_EXIT_CODE=${PIPESTATUS[0]}
      else
        RESTORE_EXIT_CODE=$?
      fi
      
      docker exec "$CONTAINER_ID" rm -f /tmp/.pgpass || true
      
      # Check exit code instead of grepping for "error"
      if [[ $RESTORE_EXIT_CODE -eq 0 ]]; then
        log_info "  -> ✓ PostgreSQL database restored successfully"
      else
        log_error "  -> Failed to restore PostgreSQL database (exit code: $RESTORE_EXIT_CODE)"
      fi
    else
      log_warn "  -> No PostgreSQL password found. Attempting restore without password..."
      RESTORE_EXIT_CODE=0
      if docker exec -i "$CONTAINER_ID" sh -c "psql -U \"$PGUSER\" -d postgres" \
        < "$SERVICE_DIR/database/pg_dumpall.sql" 2>&1 | tee "$TEMP_DIR/restore_pg.log"; then
        RESTORE_EXIT_CODE=${PIPESTATUS[0]}
      else
        RESTORE_EXIT_CODE=$?
      fi
      
      if [[ $RESTORE_EXIT_CODE -eq 0 ]]; then
        log_info "  -> ✓ PostgreSQL database restored successfully"
      else
        log_error "  -> Failed to restore PostgreSQL database (exit code: $RESTORE_EXIT_CODE)"
      fi
    fi
  fi
  
  # Restore MariaDB database
  if [[ -f "$SERVICE_DIR/mariadb_dump/all_databases.sql" ]]; then
    log_info "Restoring MariaDB database for service: ${SERVICE_NAME}"
    
    # Get database credentials from container
    CONTAINER_ENV=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_ID")
    MYSQL_USER=$(echo "$CONTAINER_ENV" | grep "^MYSQL_USER=" | cut -d= -f2- || true)
    MYSQL_ROOT_PASSWORD=$(echo "$CONTAINER_ENV" | grep "^MYSQL_ROOT_PASSWORD=" | cut -d= -f2- || true)
    MYSQL_PASSWORD=$(echo "$CONTAINER_ENV" | grep "^MYSQL_PASSWORD=" | cut -d= -f2- || true)
    MARIADB_ROOT_PASSWORD=$(echo "$CONTAINER_ENV" | grep "^MARIADB_ROOT_PASSWORD=" | cut -d= -f2- || true)
    
    DB_PASSWORD="${MYSQL_ROOT_PASSWORD:-${MARIADB_ROOT_PASSWORD:-$MYSQL_PASSWORD}}"
    DB_USER="${MYSQL_USER:-root}"
    
    # Wait for MariaDB to be ready
    wait_for_mariadb "$CONTAINER_ID" "$DB_USER" "$DB_PASSWORD"
    
    if [[ -n "$DB_PASSWORD" ]]; then
      # Create .my.cnf file for authentication
      docker exec "$CONTAINER_ID" sh -c 'printf "[client]\nuser=%s\npassword=%s\n" "$1" "$2" > /tmp/.my.cnf && chmod 600 /tmp/.my.cnf' sh "$DB_USER" "$DB_PASSWORD"
      
      # Restore database
      RESTORE_EXIT_CODE=0
      if docker exec -i "$CONTAINER_ID" sh -c "mariadb --defaults-file=/tmp/.my.cnf" \
        < "$SERVICE_DIR/mariadb_dump/all_databases.sql" 2>&1 | tee "$TEMP_DIR/restore_mariadb.log"; then
        RESTORE_EXIT_CODE=${PIPESTATUS[0]}
      else
        RESTORE_EXIT_CODE=$?
      fi
      
      docker exec "$CONTAINER_ID" rm -f /tmp/.my.cnf || true
      
      if [[ $RESTORE_EXIT_CODE -eq 0 ]]; then
        log_info "  -> ✓ MariaDB database restored successfully"
      else
        log_error "  -> Failed to restore MariaDB database (exit code: $RESTORE_EXIT_CODE)"
      fi
    else
      log_warn "  -> No MariaDB password found. Attempting restore without password..."
      RESTORE_EXIT_CODE=0
      if docker exec -i "$CONTAINER_ID" sh -c "mariadb -u \"$DB_USER\"" \
        < "$SERVICE_DIR/mariadb_dump/all_databases.sql" 2>&1 | tee "$TEMP_DIR/restore_mariadb.log"; then
        RESTORE_EXIT_CODE=${PIPESTATUS[0]}
      else
        RESTORE_EXIT_CODE=$?
      fi
      
      if [[ $RESTORE_EXIT_CODE -eq 0 ]]; then
        log_info "  -> ✓ MariaDB database restored successfully"
      else
        log_error "  -> Failed to restore MariaDB database (exit code: $RESTORE_EXIT_CODE)"
      fi
    fi
  fi
done

# --- Stack Restart Phase ---
if [[ "$SKIP_START" != "true" ]]; then
  log_info "=== Phase 7: Stack Restart ==="
  
  log_info "Restarting stack '${PROJECT_NAME}'..."
  if docker compose --project-name "${PROJECT_NAME}" restart; then
    log_info "✓ Stack restarted successfully"
  else
    log_warn "Failed to restart stack using docker compose. Attempting to restart containers individually..."
    mapfile -t CONTAINER_IDS < <(docker ps -a --filter "label=com.docker.compose.project=${PROJECT_NAME}" --format "{{.ID}}")
    if [[ ${#CONTAINER_IDS[@]} -gt 0 ]]; then
      docker restart "${CONTAINER_IDS[@]}" || log_warn "Some containers may not have restarted cleanly"
    fi
  fi
  
  # Show final state
  log_info "Final stack state:"
  docker ps -a --filter "label=com.docker.compose.project=${PROJECT_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
else
  log_info "=== Phase 7: Stack Restart [SKIPPED] ==="
fi

log_info "=== Restore Complete ==="
log_info "Stack '${PROJECT_NAME}' has been restored from backup: ${SELECTED_BACKUP}"
