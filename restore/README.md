# Restore Container

This folder contains a restore container designed to restore Docker Compose stacks from backups created by the [backup sidecar container](../backup).

## Features

- **Automatic backup discovery**: Lists and selects backups from S3-compatible storage
- **Multiple restore modes**: Restore latest backup, specific backup, or list available backups
- **Volume restoration**: Restores all volume data using `docker cp`
- **Database restoration**: Supports PostgreSQL and MariaDB logical backup restoration
- **Safe execution**: Stops stack, restores data, and restarts stack automatically
- **Flexible control**: Options to skip stopping or starting the stack
- **Integrity verification**: Verifies downloaded backups before extraction

## Requirements

- Docker with access to `/var/run/docker.sock`
- Docker Compose v2
- At least 5GB of free disk space for extraction and decompression
- S3-compatible storage with backup archives
- Network access to S3 endpoint

## Usage

### Quick Start

1. **Copy and configure environment variables**:
   ```bash
   cp .env.example .env
   # Edit .env with your actual values
   ```

2. **Run the restore container**:
   ```bash
   docker compose run --rm restore
   ```

### Environment Variables

#### Required

- `PROJECT_NAME`: Name of the stack to restore (must match the backup archive prefix)
- `S3_BUCKET_URL`: S3 bucket URL where backups are stored (e.g., `s3://my-bucket/backups`)
- `AWS_ACCESS_KEY_ID`: AWS access key ID
- `AWS_SECRET_ACCESS_KEY`: AWS secret access key
- `AWS_DEFAULT_REGION`: AWS region (e.g., `us-east-1`)

#### Optional

- `AWS_ENDPOINT_URL`: For S3-compatible storage like MinIO (e.g., `https://minio.example.com`)
- `BACKUP_FILE`: Specific backup file to restore. If not provided, restores the latest backup
- `RESTORE_MODE`: 
  - `latest` (default): Automatically restore the most recent backup
  - `specific`: Restore a specific backup (requires `BACKUP_FILE` to be set)
  - `list`: List all available backups and exit without restoring
- `SKIP_STOP`: Set to `true` to skip stopping the stack (default: `false`)
- `SKIP_START`: Set to `true` to skip starting the stack after restore (default: `false`)

**Note**: When `BACKUP_FILE` is set, the specified backup will be restored regardless of `RESTORE_MODE`. Use `RESTORE_MODE=specific` to make your intent clear when providing `BACKUP_FILE`.

## Restore Process

The restore container executes the following phases:

### Phase 1: Validation
- Validates all required environment variables
- Checks Docker socket access
- Verifies the stack exists (or warns if not found)
- Checks available disk space (requires at least 5GB)

### Phase 2: Backup Discovery
- Lists all backups in S3 for the specified project name
- Pattern: `backup_{PROJECT_NAME}_*`
- If `RESTORE_MODE=list`: Displays available backups and exits
- If `BACKUP_FILE` is specified: Validates it exists in S3
- If `RESTORE_MODE=latest`: Automatically selects the most recent backup by timestamp

### Phase 3: Stack Shutdown
- Logs current state of all containers in the stack
- Stops the entire stack: `docker compose --project-name ${PROJECT_NAME} stop`
- Waits for all containers to fully stop (with 30-second timeout)
- Verifies all containers are stopped
- Can be skipped with `SKIP_STOP=true`

### Phase 4: Backup Download & Extraction
- Downloads the selected backup from S3 to a temporary directory
- Verifies archive integrity: `zstd -t <archive>`
- Extracts the backup: `tar -I zstd -xf <archive>`
- Removes downloaded archive after extraction to save space

### Phase 5: Volume Restoration
- Discovers all services in the backup archive
- For each service:
  - Finds the corresponding container in the stack
  - Reads backup labels to determine volume paths
  - Clears existing volume content
  - Restores volume data using `docker cp`

### Phase 6: Database Restoration
- Starts containers to allow database restoration
- Waits 30 seconds for databases to be ready
- For each service with database backups:
  - **PostgreSQL**: Restores using `psql` with `.pgpass` file
  - **MariaDB**: Restores using `mariadb` command with `.my.cnf` file
  - Credentials are read from container environment variables
  - Temporary credential files are created with secure permissions (600) and deleted after use

### Phase 7: Stack Restart
- Restarts the entire stack: `docker compose --project-name ${PROJECT_NAME} restart`
- Displays final state of all containers
- Can be skipped with `SKIP_START=true`

## Examples

### Example 1: Restore Latest Backup

```bash
# .env file
PROJECT_NAME=myapp
S3_BUCKET_URL=s3://my-backup-bucket/backups
AWS_ACCESS_KEY_ID=your-key
AWS_SECRET_ACCESS_KEY=your-secret
AWS_DEFAULT_REGION=us-east-1

# Run restore
docker compose run --rm restore
```

### Example 2: List Available Backups

```bash
# .env file
PROJECT_NAME=myapp
S3_BUCKET_URL=s3://my-backup-bucket/backups
AWS_ACCESS_KEY_ID=your-key
AWS_SECRET_ACCESS_KEY=your-secret
AWS_DEFAULT_REGION=us-east-1
RESTORE_MODE=list

# Run to list backups
docker compose run --rm restore
```

### Example 3: Restore Specific Backup

```bash
# .env file
PROJECT_NAME=myapp
S3_BUCKET_URL=s3://my-backup-bucket/backups
AWS_ACCESS_KEY_ID=your-key
AWS_SECRET_ACCESS_KEY=your-secret
AWS_DEFAULT_REGION=us-east-1
BACKUP_FILE=backup_myapp_20231105-120000_abc123.tar.zst

# Run restore
docker compose run --rm restore
```

### Example 4: Restore Without Stopping/Starting Stack

Useful for manual control over the stack lifecycle:

```bash
# .env file
PROJECT_NAME=myapp
S3_BUCKET_URL=s3://my-backup-bucket/backups
AWS_ACCESS_KEY_ID=your-key
AWS_SECRET_ACCESS_KEY=your-secret
AWS_DEFAULT_REGION=us-east-1
SKIP_STOP=true
SKIP_START=true

# Manually stop your stack
docker compose -p myapp stop

# Run restore
docker compose run --rm restore

# Manually start your stack
docker compose -p myapp start
```

### Example 5: Using MinIO (S3-Compatible Storage)

```bash
# .env file
PROJECT_NAME=myapp
S3_BUCKET_URL=s3://my-backup-bucket/backups
AWS_ACCESS_KEY_ID=minioadmin
AWS_SECRET_ACCESS_KEY=minioadmin
AWS_DEFAULT_REGION=us-east-1
AWS_ENDPOINT_URL=https://minio.example.com

# Run restore
docker compose run --rm restore
```

## Backup Archive Structure

The restore container expects backup archives created by the backup sidecar container with the following structure:

```
backup_myapp_20231105-120000_abc123.tar.zst
├── service1/
│   ├── database/
│   │   └── pg_dumpall.sql
│   └── volumes/
│       ├── uploads/
│       └── config/
└── service2/
    └── mariadb_dump/
        └── all_databases.sql
```

### Archive Naming Convention

Backup archives follow this naming pattern:
```
backup_{PROJECT_NAME}_{TIMESTAMP}_{UUID}.tar.zst
```

- `PROJECT_NAME`: The name of the Docker Compose stack
- `TIMESTAMP`: Format `YYYYMMDD-HHMMSS` (e.g., `20231105-120000`)
- `UUID`: Unique identifier for the backup (shortened, e.g., `abc123`)
- `.tar.zst`: Compressed with Zstandard

## Compatibility

The restore container is designed to work with backups created by the backup sidecar container in this repository. It supports:

- **PostgreSQL logical backups**: Created with `pg_dumpall`
- **MariaDB logical backups**: Created with `mariadb-dump`
- **Volume/file backups**: Any directories backed up with `backup.volume-path.*` labels

**Note**: Physical database backups (raw data directories) should not be restored using this container. Physical backups are file-level backups and are restored as volumes.

## Troubleshooting

### No backups found

**Error**: `No backups found for project 'myapp' in S3 bucket`

**Solutions**:
- Verify `PROJECT_NAME` matches the backup archive prefix
- Check S3 credentials and bucket URL
- Verify backups exist in S3: `aws s3 ls ${S3_BUCKET_URL}/`
- Ensure backup naming follows the pattern: `backup_{PROJECT_NAME}_*`

### Insufficient disk space

**Error**: `Insufficient disk space. Required: 5GB, Available: XGB`

**Solutions**:
- Free up disk space in `/tmp` directory
- Remove old temporary files
- Increase disk allocation for the Docker host

### Container not found for service

**Warning**: `No container found for service 'xxx'. Skipping volume restoration.`

**Explanation**: This warning appears when a service exists in the backup but no corresponding container is found in the current stack. This is expected if:
- The stack structure has changed since the backup
- You're restoring to a fresh stack that isn't running yet
- The service was removed from the stack

**Solutions**:
- If restoring to a fresh stack, ensure all containers are created first (even if stopped)
- Verify the `PROJECT_NAME` matches between backup and current stack
- Check that container labels include `com.docker.compose.project` and `com.docker.compose.service`

### Database restore fails

**Error**: `Failed to restore PostgreSQL/MariaDB database`

**Solutions**:
- Verify database credentials in container environment variables
- Check database container is running and healthy
- Review error logs in the restore output
- Ensure database user has sufficient permissions
- For PostgreSQL: Check `POSTGRES_USER` and `POSTGRES_PASSWORD`
- For MariaDB: Check `MYSQL_USER`, `MYSQL_ROOT_PASSWORD`, or `MARIADB_ROOT_PASSWORD`

### Docker socket access denied

**Error**: `Cannot access Docker daemon. Is /var/run/docker.sock mounted?`

**Solutions**:
- Verify `/var/run/docker.sock` is mounted in the restore container
- Check Docker socket permissions: `ls -la /var/run/docker.sock`
- Ensure the user running the container has Docker access

### Archive integrity check failed

**Error**: `Archive integrity check failed`

**Solutions**:
- The backup archive may be corrupted
- Try downloading the backup again
- Verify the backup in S3 is complete and not truncated
- Check network stability during download

## Security Considerations

- **Docker Socket Access**: The restore container requires access to `/var/run/docker.sock`, which grants significant control over the Docker daemon. Only run in trusted environments.
- **Credentials**: Database passwords are read from container environment variables. Use Docker secrets or env files for sensitive data.
- **S3 Credentials**: AWS credentials are passed via environment variables. Consider using IAM roles or instance profiles in production.
- **Temporary Files**: All temporary files are stored in `/tmp` and cleaned up after restore completes.
- **Credential Files**: Temporary credential files (`.pgpass`, `.my.cnf`) are created with restrictive permissions (600) inside target containers and deleted after use.

## Best Practices

### Before Restore

1. **Verify the backup**: List available backups first using `RESTORE_MODE=list`
2. **Stop client access**: Ensure no users are accessing the application during restore
3. **Backup current state**: Consider creating a backup of the current state before restoring
4. **Check disk space**: Ensure sufficient disk space is available (at least 5GB + backup size)

### During Restore

1. **Monitor progress**: Watch the restore container logs for any warnings or errors
2. **Be patient**: Large restores can take significant time, especially for databases
3. **Don't interrupt**: Avoid interrupting the restore process to prevent data corruption

### After Restore

1. **Verify data**: Check that all data was restored correctly
2. **Test application**: Ensure the application functions as expected
3. **Check logs**: Review container logs for any errors after restore
4. **Monitor performance**: Watch for any performance issues after restore

### Testing Restore

1. **Test regularly**: Regularly test your restore process to ensure backups are valid
2. **Use a staging environment**: Test restores in a staging environment before production
3. **Verify completeness**: Check that all volumes and databases are restored
4. **Time the restore**: Know how long a restore takes for capacity planning

## Differences from Backup Container

| Feature | Backup Container | Restore Container |
|---------|------------------|-------------------|
| **Execution** | Runs continuously with cron | Runs once then exits |
| **Discovery** | Auto-discovers all stacks on host | Requires explicit `PROJECT_NAME` |
| **Direction** | Local → S3 | S3 → Local |
| **Container State** | Manages container stop/start | Manages container stop/start |
| **Credentials** | Reads from target containers | Reads from target containers |

## Integration with Backup Sidecar

The restore container is designed to work seamlessly with the [backup sidecar container](../backup):

1. **Naming Convention**: Restore container understands the backup naming pattern used by the backup sidecar
2. **Archive Structure**: Restore container expects the archive structure created by the backup sidecar
3. **Labels**: Restore container reads the same labels (`backup.volume-path.*`) used by the backup sidecar
4. **Credentials**: Both containers read credentials from the same environment variables in target containers

## Limitations

- **Physical database backups**: Physical backups (raw data directories) are restored as volumes, not through database commands
- **Cross-platform**: Backups created on one architecture may not restore correctly on a different architecture
- **Version compatibility**: Database backups may not restore correctly if the database version differs significantly
- **Network configuration**: Network configurations are not backed up or restored
- **Secrets**: Docker secrets are not backed up or restored
- **External dependencies**: External services or dependencies must be configured separately

## Future Enhancements

Potential improvements for future versions:

- Support for incremental restores
- Parallel volume restoration for faster restores
- Pre-restore validation to check for common issues
- Post-restore health checks
- Restore progress indicators
- Support for restoring to a different project name
- Automatic rollback on failure
- Support for encrypted backups
