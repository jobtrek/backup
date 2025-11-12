#!/bin/bash
# Note: We don't use 'set -e' here because we have explicit error handling throughout
# the script. This allows us to handle failures gracefully and continue with remaining
# backups when one container fails, rather than aborting the entire process.
set -o pipefail

# --- Logging Functions ---
log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

# --- Configuration (from Environment Variables) ---
: "${S3_BUCKET_URL?Missing S3_BUCKET_URL env var}"
: "${AWS_ACCESS_KEY_ID?Missing AWS_ACCESS_KEY_ID env var}"
: "${AWS_SECRET_ACCESS_KEY?Missing AWS_SECRET_ACCESS_KEY env var}"
: "${AWS_DEFAULT_REGION?Missing AWS_DEFAULT_REGION env var}"

log_info "=== Enhanced Backup Sidecar Container Starting ==="
log_info "Discovering all compose stacks with backup.enable=true labels..."

# --- Discover all compose stacks with backup-enabled containers ---
mapfile -t ALL_PROJECTS < <(
	docker ps -a \
		--filter "label=backup.enable=true" \
		--format "{{.Label \"com.docker.compose.project\"}}" | sort -u
)

if ((${#ALL_PROJECTS[@]} == 0)); then
	log_info "No compose stacks found with containers labeled 'backup.enable=true'. Exiting."
	exit 0
fi

log_info "Found ${#ALL_PROJECTS[@]} compose stack(s) to backup:"
printf '  - %s\n' "${ALL_PROJECTS[@]}"

# Track overall success
BACKUP_FAILED=0

# --- Process each stack one at a time ---
for PROJECT_NAME in "${ALL_PROJECTS[@]}"; do
	log_info ""
	log_info "========================================"
	log_info "Starting backup for stack: ${PROJECT_NAME}"
	log_info "========================================"

	# Generate unique identifiers
	TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
	UUID=$(uuidgen)
	BACKUP_DIR=$(mktemp -d)
	ARCHIVE_NAME="backup_${PROJECT_NAME}_${TIMESTAMP}_${UUID}.tar.zst"
	ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"

	# Discover all containers in this stack with backup.enable=true
	mapfile -t BACKUP_CONTAINERS < <(
		docker ps -a \
			--filter "label=com.docker.compose.project=${PROJECT_NAME}" \
			--filter "label=backup.enable=true" \
			--format "{{.ID}}:{{.Label \"com.docker.compose.service\"}}"
	)

	if ((${#BACKUP_CONTAINERS[@]} == 0)); then
		log_warn "No containers with backup.enable=true found in stack ${PROJECT_NAME}. Skipping."
		rm -rf "$BACKUP_DIR"
		continue
	fi

	log_info "Found ${#BACKUP_CONTAINERS[@]} container(s) to backup in stack ${PROJECT_NAME}"

	# Track containers that need to be stopped
	CONTAINERS_TO_STOP=()
	declare -A CONTAINER_DATA=()

	# --- Analyze each container ---
	for ENTRY in "${BACKUP_CONTAINERS[@]}"; do
		CONTAINER_ID="${ENTRY%%:*}"
		SERVICE_NAME="${ENTRY#*:}"

		log_info "Analyzing container: ${SERVICE_NAME} (${CONTAINER_ID})"

		# Check for database backup labels
		PG_DUMPALL=$(docker inspect --format='{{index .Config.Labels "backup.database.pg_dumpall"}}' "$CONTAINER_ID")
		MARIADB_DUMP=$(docker inspect --format='{{index .Config.Labels "backup.database.mariadb-dump"}}' "$CONTAINER_ID")

		# Check for volume backup labels
		mapfile -t VOLUME_LABELS_CHECK < <(
			docker inspect "$CONTAINER_ID" --format='{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' | grep '^backup\.volume-path\.'
		)
		HAS_VOLUME_BACKUP=$((${#VOLUME_LABELS_CHECK[@]} > 0))
		if ((${#VOLUME_LABELS_CHECK[@]} > 0)); then
			CONTAINER_DATA["${CONTAINER_ID}_volume_labels"]=$(printf '%s\n' "${VOLUME_LABELS_CHECK[@]}")
		else
			CONTAINER_DATA["${CONTAINER_ID}_volume_labels"]=""
		fi
		CONTAINER_DATA["${CONTAINER_ID}_has_volume_backup"]="$HAS_VOLUME_BACKUP"

		# If both logical backup and volume backup are configured, skip logical backup
		SKIP_LOGICAL_BACKUP=false
		if [[ "$HAS_VOLUME_BACKUP" -eq 1 ]] && [[ "$PG_DUMPALL" == "true" || "$MARIADB_DUMP" == "true" ]]; then
			SKIP_LOGICAL_BACKUP=true
			log_warn "  -> Detected both logical and volume backups for ${SERVICE_NAME}. Logical backup will be skipped to avoid copying live database files while running. Review your backup strategy."
		fi

		# Store container info
		CONTAINER_DATA["${CONTAINER_ID}_service"]="$SERVICE_NAME"
		CONTAINER_DATA["${CONTAINER_ID}_pg_dumpall"]="$PG_DUMPALL"
		CONTAINER_DATA["${CONTAINER_ID}_mariadb_dump"]="$MARIADB_DUMP"
		CONTAINER_DATA["${CONTAINER_ID}_skip_logical"]="$SKIP_LOGICAL_BACKUP"

		# If no database logical backup (or it's being skipped), container can be stopped
		if [[ "$SKIP_LOGICAL_BACKUP" == "true" ]] || [[ "$PG_DUMPALL" != "true" && "$MARIADB_DUMP" != "true" ]]; then
			CONTAINERS_TO_STOP+=("$SERVICE_NAME")
			log_info "  -> Will be stopped for backup"
		else
			log_info "  -> Will remain running (logical database backup)"
		fi
	done

	# --- Cleanup function for this stack ---
	cleanup_stack() {
		local exit_code=$?
		if ((${#CONTAINERS_TO_STOP[@]} > 0)); then
			log_info "--- Restarting stopped containers ---"
			if ! docker compose --project-name "${PROJECT_NAME}" start "${CONTAINERS_TO_STOP[@]}"; then
				log_error "Failed to restart containers for stack ${PROJECT_NAME}"
			fi
		fi
		log_info "Cleaning up temp directory: $BACKUP_DIR"
		rm -rf "$BACKUP_DIR"
		return $exit_code
	}
	trap cleanup_stack EXIT

	# Validate available disk space (require at least 1GB free)
	AVAILABLE_SPACE=$(df -BG "$(dirname "$BACKUP_DIR")" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//' | tr -d '[:space:]')
	# Validate that AVAILABLE_SPACE is a number
	if ! [[ "$AVAILABLE_SPACE" =~ ^[0-9]+$ ]]; then
		log_error "Could not determine available disk space. Skipping stack ${PROJECT_NAME}"
		trap - EXIT
		cleanup_stack
		BACKUP_FAILED=1
		continue
	fi
	if [[ "$AVAILABLE_SPACE" -lt 1 ]]; then
		log_error "Insufficient disk space (${AVAILABLE_SPACE}GB available). Skipping stack ${PROJECT_NAME}"
		trap - EXIT
		cleanup_stack
		BACKUP_FAILED=1
		continue
	fi

	# --- Stop containers that need to be stopped ---
	if ((${#CONTAINERS_TO_STOP[@]} > 0)); then
		log_info "--- Stopping containers for physical backup ---"
		# Remove duplicates
		mapfile -t UNIQUE_STOP < <(printf '%s\n' "${CONTAINERS_TO_STOP[@]}" | sort -u)
		if ! docker compose --project-name "${PROJECT_NAME}" stop "${UNIQUE_STOP[@]}"; then
			log_error "Failed to stop containers for stack ${PROJECT_NAME}"
			trap - EXIT
			cleanup_stack
			BACKUP_FAILED=1
			continue
		fi
		log_info "Stopped ${#UNIQUE_STOP[@]} container(s)"
	fi

	# --- Create backup directory structure ---
	mkdir -p "$BACKUP_DIR"

	# --- Process each container's backup ---
	for ENTRY in "${BACKUP_CONTAINERS[@]}"; do
		CONTAINER_ID="${ENTRY%%:*}"
		SERVICE_NAME="${ENTRY#*:}"

		CONTAINER_BACKUP_DIR="${BACKUP_DIR}/${SERVICE_NAME}"
		mkdir -p "$CONTAINER_BACKUP_DIR"

		log_info "--- Backing up container: ${SERVICE_NAME} ---"

		CONTAINER_ENV=""
		if [[ "${CONTAINER_DATA[${CONTAINER_ID}_pg_dumpall]}" == "true" || "${CONTAINER_DATA[${CONTAINER_ID}_mariadb_dump]}" == "true" ]]; then
			# Only get container env if logical backup is not being skipped
			if [[ "${CONTAINER_DATA[${CONTAINER_ID}_skip_logical]}" != "true" ]]; then
				CONTAINER_ENV=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_ID")
			fi
		fi

		# --- Handle PostgreSQL logical backup (pg_dumpall) ---
		if [[ "${CONTAINER_DATA[${CONTAINER_ID}_pg_dumpall]}" == "true" ]]; then
			if [[ "${CONTAINER_DATA[${CONTAINER_ID}_skip_logical]}" == "true" ]]; then
				log_warn "Skipping PostgreSQL logical backup for ${SERVICE_NAME} (volume backup takes precedence)"
			else
				log_info "Performing PostgreSQL logical backup (pg_dumpall) via docker exec..."

				# Extract env vars using cut -f2- to handle values containing '='
				PGUSER=$(echo "$CONTAINER_ENV" | grep "^POSTGRES_USER=" | cut -d= -f2- || true)
				PGPASSWORD=$(echo "$CONTAINER_ENV" | grep "^POSTGRES_PASSWORD=" | cut -d= -f2- || true)

				PGUSER="${PGUSER:-postgres}"

				if [[ -z "$PGPASSWORD" || "$PGPASSWORD" == "<no value>" ]]; then
					# The file POSTGRES_PASSWORD_FILE might be used
					PGPASSWORD_FILE=$(echo "$CONTAINER_ENV" | grep "^POSTGRES_PASSWORD_FILE=" | cut -d= -f2- || true)
					if [[ -n "$PGPASSWORD_FILE" && "$PGPASSWORD_FILE" != "<no value>" ]]; then
						log_info "  -> Found POSTGRES_PASSWORD_FILE, reading password from file inside the container."
						PGPASSWORD=$(docker exec "$CONTAINER_ID" cat "$PGPASSWORD_FILE" 2>/dev/null || true)
					fi
				fi

				if [[ -z "$PGPASSWORD" ]]; then
					log_warn "  -> POSTGRES_PASSWORD not found in container environment. Attempting without password..."
				fi

				mkdir -p "$CONTAINER_BACKUP_DIR/database"

				# Use stdin for password to avoid process list exposure
				if [[ -n "$PGPASSWORD" ]]; then
					# Create .pgpass file inside container using printf for better robustness
					docker exec "$CONTAINER_ID" sh -c 'printf "*:*:*:%s:%s\n" "$1" "$2" > /tmp/.pgpass && chmod 600 /tmp/.pgpass' sh "$PGUSER" "$PGPASSWORD" || {
						log_error "Failed to create .pgpass file for ${SERVICE_NAME}"
					}

					# Run pg_dumpall using .pgpass
					if docker exec -i \
						--env "PGPASSFILE=/tmp/.pgpass" \
						"$CONTAINER_ID" sh -c "pg_dumpall --clean --if-exists -U \"$PGUSER\" -w" \
						>"$CONTAINER_BACKUP_DIR/database/pg_dumpall.sql" 2>"$CONTAINER_BACKUP_DIR/database/pg_dumpall.errors"; then

						# Cleanup .pgpass
						docker exec "$CONTAINER_ID" rm -f /tmp/.pgpass || true

						# Check if errors file is empty or contains only warnings
						if [[ ! -s "$CONTAINER_BACKUP_DIR/database/pg_dumpall.errors" ]] || ! grep -q -i "error" "$CONTAINER_BACKUP_DIR/database/pg_dumpall.errors"; then
							rm -f "$CONTAINER_BACKUP_DIR/database/pg_dumpall.errors"
						fi

						# Verify backup is not empty
						if [[ -s "$CONTAINER_BACKUP_DIR/database/pg_dumpall.sql" ]]; then
							log_info "  -> PostgreSQL logical backup completed ($(stat -c%s "$CONTAINER_BACKUP_DIR/database/pg_dumpall.sql" | numfmt --to=iec-i --suffix=B))"
						else
							log_error "  -> PostgreSQL backup is empty for ${SERVICE_NAME}"
						fi
					else
						log_error "  -> Failed to perform pg_dumpall for ${SERVICE_NAME}. Check error log in backup archive."
						docker exec "$CONTAINER_ID" rm -f /tmp/.pgpass || true
					fi
				else
					# Attempt without password
					if docker exec -i "$CONTAINER_ID" sh -c "pg_dumpall --clean --if-exists -U \"$PGUSER\" -w" \
						>"$CONTAINER_BACKUP_DIR/database/pg_dumpall.sql" 2>"$CONTAINER_BACKUP_DIR/database/pg_dumpall.errors"; then

						if [[ ! -s "$CONTAINER_BACKUP_DIR/database/pg_dumpall.errors" ]] || ! grep -q -i "error" "$CONTAINER_BACKUP_DIR/database/pg_dumpall.errors"; then
							rm -f "$CONTAINER_BACKUP_DIR/database/pg_dumpall.errors"
						fi

						if [[ -s "$CONTAINER_BACKUP_DIR/database/pg_dumpall.sql" ]]; then
							log_info "  -> PostgreSQL logical backup completed ($(stat -c%s "$CONTAINER_BACKUP_DIR/database/pg_dumpall.sql" | numfmt --to=iec-i --suffix=B))"
						else
							log_error "  -> PostgreSQL backup is empty for ${SERVICE_NAME}"
						fi
					else
						log_error "  -> Failed to perform pg_dumpall for ${SERVICE_NAME}. Check error log in backup archive."
					fi
				fi
			fi
		fi

		# --- Handle MariaDB backup ---
		if [[ "${CONTAINER_DATA[${CONTAINER_ID}_mariadb_dump]}" == "true" ]]; then
			if [[ "${CONTAINER_DATA[${CONTAINER_ID}_skip_logical]}" == "true" ]]; then
				log_warn "Skipping MariaDB logical backup for ${SERVICE_NAME} (volume backup takes precedence)"
			else
				log_info "  -> Performing MariaDB dump..."

				# Extract env vars using cut -f2- to handle values containing '='
				MYSQL_USER=$(echo "$CONTAINER_ENV" | grep "^MYSQL_USER=" | cut -d= -f2- || true)
				MYSQL_ROOT_PASSWORD=$(echo "$CONTAINER_ENV" | grep "^MYSQL_ROOT_PASSWORD=" | cut -d= -f2- || true)
				MYSQL_PASSWORD=$(echo "$CONTAINER_ENV" | grep "^MYSQL_PASSWORD=" | cut -d= -f2- || true)
				MARIADB_ROOT_PASSWORD=$(echo "$CONTAINER_ENV" | grep "^MARIADB_ROOT_PASSWORD=" | cut -d= -f2- || true)

				# Prefer root password
				DB_PASSWORD="${MYSQL_ROOT_PASSWORD:-${MARIADB_ROOT_PASSWORD:-$MYSQL_PASSWORD}}"
				DB_USER="${MYSQL_USER:-root}"

				if [[ -z "$DB_PASSWORD" ]]; then
					log_warn "  -> No MariaDB password found in container environment. Attempting without password..."
				fi

				mkdir -p "$CONTAINER_BACKUP_DIR/mariadb_dump"

				# Use stdin for password to avoid process list exposure
				if [[ -n "$DB_PASSWORD" ]]; then
					# Create .my.cnf file inside container using printf to avoid shell injection
					docker exec "$CONTAINER_ID" sh -c 'printf "[client]\nuser=%s\npassword=%s\n" "$1" "$2" > /tmp/.my.cnf && chmod 600 /tmp/.my.cnf' sh "$DB_USER" "$DB_PASSWORD" || {
						log_error "Failed to create .my.cnf file for ${SERVICE_NAME}"
					}

					# Run mariadb-dump using .my.cnf
					if docker exec -i "$CONTAINER_ID" sh -c "mariadb-dump --defaults-file=/tmp/.my.cnf --all-databases" \
						>"$CONTAINER_BACKUP_DIR/mariadb_dump/all_databases.sql" 2>"$CONTAINER_BACKUP_DIR/mariadb_dump/mariadb_dump.errors"; then

						# Cleanup .my.cnf
						docker exec "$CONTAINER_ID" rm -f /tmp/.my.cnf || true

						if [[ ! -s "$CONTAINER_BACKUP_DIR/mariadb_dump/mariadb_dump.errors" ]] || ! grep -q -i "error" "$CONTAINER_BACKUP_DIR/mariadb_dump/mariadb_dump.errors"; then
							rm -f "$CONTAINER_BACKUP_DIR/mariadb_dump/mariadb_dump.errors"
						fi

						# Verify backup is not empty
						if [[ -s "$CONTAINER_BACKUP_DIR/mariadb_dump/all_databases.sql" ]]; then
							log_info "  -> MariaDB dump completed ($(stat -c%s "$CONTAINER_BACKUP_DIR/mariadb_dump/all_databases.sql" | numfmt --to=iec-i --suffix=B))"
						else
							log_error "  -> MariaDB backup is empty for ${SERVICE_NAME}"
						fi
					else
						log_error "  -> mariadb-dump failed for ${SERVICE_NAME}. Check error log in backup archive."
						docker exec "$CONTAINER_ID" rm -f /tmp/.my.cnf || true
					fi
				else
					# Attempt without password
					if docker exec -i "$CONTAINER_ID" sh -c "mariadb-dump --all-databases -u \"$DB_USER\"" \
						>"$CONTAINER_BACKUP_DIR/mariadb_dump/all_databases.sql" 2>"$CONTAINER_BACKUP_DIR/mariadb_dump/mariadb_dump.errors"; then

						if [[ ! -s "$CONTAINER_BACKUP_DIR/mariadb_dump/mariadb_dump.errors" ]] || ! grep -q -i "error" "$CONTAINER_BACKUP_DIR/mariadb_dump/mariadb_dump.errors"; then
							rm -f "$CONTAINER_BACKUP_DIR/mariadb_dump/mariadb_dump.errors"
						fi

						if [[ -s "$CONTAINER_BACKUP_DIR/mariadb_dump/all_databases.sql" ]]; then
							log_info "  -> MariaDB dump completed ($(stat -c%s "$CONTAINER_BACKUP_DIR/mariadb_dump/all_databases.sql" | numfmt --to=iec-i --suffix=B))"
						else
							log_error "  -> MariaDB backup is empty for ${SERVICE_NAME}"
						fi
					else
						log_error "  -> mariadb-dump failed for ${SERVICE_NAME}. Check error log in backup archive."
					fi
				fi
			fi
		fi

		# --- Handle volume path backups ---
		VOLUME_LABELS_RAW="${CONTAINER_DATA[${CONTAINER_ID}_volume_labels]}"
		if [[ -n "$VOLUME_LABELS_RAW" ]]; then
			mapfile -t VOLUME_LABELS <<<"$VOLUME_LABELS_RAW"
		else
			VOLUME_LABELS=()
		fi

		if ((${#VOLUME_LABELS[@]} > 0)); then
			log_info "Found ${#VOLUME_LABELS[@]} volume path(s) to backup"
			mkdir -p "$CONTAINER_BACKUP_DIR/volumes"

			for LABEL in "${VOLUME_LABELS[@]}"; do
				# Parse label: backup.volume-path.NAME=PATH
				LABEL_KEY="${LABEL%%=*}"
				LABEL_VALUE="${LABEL#*=}"

				# Extract the name from the label key using parameter expansion
				VOLUME_NAME="${LABEL_KEY#backup.volume-path.}"

				if [[ -z "$LABEL_VALUE" || "$LABEL_VALUE" == "<no value>" ]]; then
					log_warn "Empty path for label ${LABEL_KEY}, skipping"
					continue
				fi

				log_info "Backing up volume: ${VOLUME_NAME} from path: ${LABEL_VALUE}"
				DEST_DIR="$CONTAINER_BACKUP_DIR/volumes/${VOLUME_NAME}"
				mkdir -p "$DEST_DIR"

				if docker cp "$CONTAINER_ID:$LABEL_VALUE/." "$DEST_DIR/"; then
					log_info "  -> Volume backup completed"
				else
					log_error "  -> Failed to copy ${LABEL_VALUE} from ${SERVICE_NAME}"
				fi
			done
		fi

		log_info "Container ${SERVICE_NAME} backup completed"
	done

	# --- Create and compress archive ---
	log_info "--- Creating compressed archive ---"
	# Default to 0 (all cores) for zstd threads
	ZSTD_THREADS_VALUE="${ZSTD_THREADS:-0}"

	# Create tar of all directories in backup dir except the archive itself
	if ! cd "$BACKUP_DIR"; then
		log_error "Failed to change to backup directory: $BACKUP_DIR"
		trap - EXIT
		cleanup_stack
		BACKUP_FAILED=1
		continue
	fi

	shopt -s nullglob
	DIRS_TO_BACKUP=()
	for dir in */; do
		if [[ -d "$dir" ]]; then
			DIRS_TO_BACKUP+=("${dir%/}")
		fi
	done

	if ((${#DIRS_TO_BACKUP[@]} > 0)); then
		if tar -c "${DIRS_TO_BACKUP[@]}" | zstd -T"$ZSTD_THREADS_VALUE" - -o "$ARCHIVE_PATH"; then
			ARCHIVE_SIZE=$(stat -c%s "$ARCHIVE_PATH" | numfmt --to=iec-i --suffix=B)
			log_info "Archive created: $ARCHIVE_PATH (${ARCHIVE_SIZE})"

			# Verify archive integrity
			if zstd -t "$ARCHIVE_PATH" >/dev/null 2>&1; then
				log_info "  -> Archive integrity verified"
			else
				log_error "  -> Archive integrity check failed!"
				trap - EXIT
				cleanup_stack
				BACKUP_FAILED=1
				continue
			fi
		else
			log_error "Failed to create archive for stack ${PROJECT_NAME}"
			trap - EXIT
			cleanup_stack
			BACKUP_FAILED=1
			continue
		fi
	else
		log_warn "No data to backup for stack ${PROJECT_NAME}"
		trap - EXIT
		cleanup_stack
		continue
	fi

	# --- Upload to S3 ---
	log_info "--- Uploading to S3 ---"
	if aws s3 cp "$ARCHIVE_PATH" "${S3_BUCKET_URL%/}/${ARCHIVE_NAME}"; then
		log_info "Upload complete: ${ARCHIVE_NAME}"
	else
		log_error "Failed to upload ${ARCHIVE_NAME} to S3"
		trap - EXIT
		cleanup_stack
		BACKUP_FAILED=1
		continue
	fi

	# --- Cleanup ---
	trap - EXIT
	cleanup_stack

	log_info "========================================"
	log_info "Backup completed for stack: ${PROJECT_NAME}"
	log_info "========================================"
done

log_info ""
if [[ $BACKUP_FAILED -eq 0 ]]; then
	log_info "=== All backups completed successfully ==="
	exit 0
else
	log_error "=== Some backups failed. Check logs above ==="
	exit 1
fi
