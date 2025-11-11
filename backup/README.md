# Enhanced Backup Sidecar Container

This folder contains an enhanced backup sidecar container designed to run **one instance per host** and automatically discover and backup all Docker Compose stacks.

## Features

- **Host-level backup**: One sidecar container per host instead of per stack
- **Automatic discovery**: Discovers all compose stacks with backup-enabled containers via Docker labels
- **Label-driven configuration**: Control backups entirely through Docker labels
- **Multiple backup types**: Support for PostgreSQL (logical & physical), MariaDB, and file/volume backups
- **Organized archives**: Creates one archive per stack with organized folder structure
- **S3 upload**: Automatically uploads compressed backups to S3-compatible storage

## Supported Backup Types

### Volume/File Backups

Use the `backup.volume-path.*` labels to backup directories:

```yaml
labels:
  - "backup.enable=true"
  - "backup.volume-path.uploads=/var/www/uploads"
  - "backup.volume-path.config=/etc/myapp/config"
```

### PostgreSQL Backups

**Logical backup (pg_dumpall)** - Container remains running:
```yaml
labels:
  - "backup.enable=true"
  - "backup.database.pg_dumpall=true"
environment:
  # POSTGRES_USER is optional (defaults to "postgres")
  - POSTGRES_USER=myuser 
  # POSTGRES_PASSWORD or POSTGRES_PASSWORD_FILE is required
  - POSTGRES_PASSWORD=mypassword
  # - POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password
```

**Physical backup (data directory)** - Container is stopped:

For physical database backups, use the standard directory backup approach with `backup.volume-path.*` labels. This is simpler and treats database files like any other data directory:

```yaml
labels:
  - "backup.enable=true"
  - "backup.volume-path.pgdata=/var/lib/postgresql/data"
```

**Note:** Physical backups require the database container to be stopped to ensure data consistency. The backup system automatically stops containers that only have directory backups (no logical database dumps) and prioritizes the directory backup if both strategies are configured.

**WARNING: Do Not Mix Backup Strategies**

Configuring both a logical database backup (for example, `backup.database.pg_dumpall=true`) and a physical backup of the database directory (using `backup.volume-path.*`) on the **same service** is unsafe and unsupported. Physical backups need the database to be stopped; attempting to copy live database files will likely produce a **corrupt and unusable backup**. The backup sidecar now skips the logical dump if both are present, but you should explicitly choose one strategy per service or split the workloads across separate containers.

### MariaDB Backups

**Logical backup (mariadb-dump)** - Container remains running:
```yaml
labels:
  - "backup.enable=true"
  - "backup.database.mariadb-dump=true"
environment:
  # One of the following password variables is required
  - MARIADB_ROOT_PASSWORD=rootpassword
  # OR
  - MYSQL_ROOT_PASSWORD=rootpassword
  # MYSQL_USER is optional (defaults to "root")
  - MYSQL_USER=root
```

**Physical backup (data directory)** - Container is stopped:

For physical database backups, use the standard directory backup approach with `backup.volume-path.*` labels:

```yaml
labels:
  - "backup.enable=true"
  - "backup.volume-path.mariadb=/var/lib/mysql"
```

**Note:** Physical backups require the database container to be stopped to ensure data consistency. The backup system automatically stops containers that only have directory backups (no logical database dumps) and prioritizes the directory backup if both strategies are configured.

**WARNING: Do Not Mix Backup Strategies**

Combining `backup.database.mariadb-dump=true` with a `backup.volume-path.*` label on the **same service** is unsafe and unsupported. Physical backups depend on the database container being stopped; copying live MariaDB files will likely result in a **corrupt and unusable backup**. The backup sidecar skips the logical dump when both are present, so pick one backup method per service or run separate containers for each strategy.

## Usage Example

### Backup Sidecar Container (One per host)

Create a `docker-compose.yml` for the backup sidecar:

```yaml
version: '3.8'

services:
  backup-sidecar:
    build:
      context: ./backup
      dockerfile: Dockerfile
    restart: always
    environment:
      # Cron schedule (default: 0 2 * * * = 2 AM daily)
      - CRON_SCHEDULE=0 2 * * *
      
      # S3 Configuration
      - S3_BUCKET_URL=s3://my-backup-bucket/backups
      - AWS_ACCESS_KEY_ID=your-access-key
      - AWS_SECRET_ACCESS_KEY=your-secret-key
      - AWS_DEFAULT_REGION=us-east-1
      
      # Optional: Limit zstd compression threads (default: all cores)
      - ZSTD_THREADS=4
    volumes:
      # REQUIRED: Access to Docker daemon
      - /var/run/docker.sock:/var/run/docker.sock
```

> **Note:** Since logical database backups now use `docker exec` to run commands inside the target containers, the backup sidecar does not require network connectivity to application stacks. It only needs access to the Docker socket and network access to your S3 endpoint.

### Application Stack Example

Here's an example application stack with backup labels:

```yaml
version: '3.8'

services:
  db:
    image: postgres:16-alpine
    restart: always
    environment:
      - POSTGRES_USER=appuser
      - POSTGRES_PASSWORD=apppass
      - POSTGRES_DB=appdb
    volumes:
      - db_data:/var/lib/postgresql/data
    labels:
      # Enable backup for this container
      - "backup.enable=true"
      # Use logical backup (pg_dumpall)
      - "backup.database.pg_dumpall=true"

  app:
    image: my-app:latest
    restart: always
    depends_on:
      - db
    volumes:
      - app_uploads:/app/uploads
      - app_config:/app/config
    labels:
      # Enable backup for this container
      - "backup.enable=true"
      # Backup multiple directories
      - "backup.volume-path.uploads=/app/uploads"
      - "backup.volume-path.config=/app/config"

volumes:
  db_data:
  app_uploads:
  app_config:
```

### MariaDB Example

```yaml
version: '3.8'

services:
  mariadb:
    image: mariadb:10.11
    restart: always
    environment:
      - MARIADB_ROOT_PASSWORD=rootpass
      - MARIADB_DATABASE=mydb
      - MARIADB_USER=dbuser
      - MARIADB_PASSWORD=dbpass
    volumes:
      - mariadb_data:/var/lib/mysql
    labels:
      - "backup.enable=true"
      # Use MariaDB logical backup
      - "backup.database.mariadb-dump=true"

  web:
    image: nginx:alpine
    volumes:
      - web_content:/usr/share/nginx/html
    labels:
      - "backup.enable=true"
      - "backup.volume-path.html=/usr/share/nginx/html"

volumes:
  mariadb_data:
  web_content:
```

## How It Works

1. **Discovery Phase**: The backup script discovers all Docker Compose stacks on the host that have at least one container with `backup.enable=true`

2. **Sequential Processing**: Each stack is processed one at a time to manage system resources. Errors in one stack don't prevent other stacks from being backed up.

3. **Container Analysis**: For each stack, all containers with `backup.enable=true` are analyzed for backup labels

4. **Disk Space Validation**: Checks that at least 1GB of free disk space is available before starting the backup

5. **Smart Stopping**: 
   - Containers with logical database backups (`pg_dumpall`, `mariadb-dump`) remain running
   - Containers with only file/volume backups or physical database backups are stopped

6. **Secure Backup Execution**: 
   - PostgreSQL: Creates temporary `.pgpass` file inside container with secure permissions (600)
   - MariaDB: Creates temporary `.my.cnf` file inside container with secure permissions (600)
   - File backups: Uses `docker cp` to copy volume contents
   - All temporary credential files are deleted after use

7. **Backup Verification**: 
   - SQL dumps are checked to ensure they're not empty
   - File size is reported for each backup component

8. **Archive Creation**: An archive is created with the naming pattern: `backup-{stack-name}-{timestamp}-{uuid}.tar.zst`

9. **Archive Structure**:
   ```
   backup-mystack-20231105-120000-uuid.tar.zst
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

10. **Integrity Verification**: Archive is tested with `zstd -t` to ensure it's valid

11. **Upload**: The compressed archive is uploaded to the configured S3 bucket

12. **Guaranteed Cleanup**: Temporary files are removed and stopped containers are restarted (even if errors occurred)

## Environment Variables

### Required
- `S3_BUCKET_URL`: S3 bucket URL (e.g., `s3://my-bucket/path`)
- `AWS_ACCESS_KEY_ID`: AWS access key
- `AWS_SECRET_ACCESS_KEY`: AWS secret key
- `AWS_DEFAULT_REGION`: AWS region

### Optional
- `CRON_SCHEDULE`: Cron schedule (default: `0 2 * * *` - 2 AM daily)
- `ZSTD_THREADS`: Number of compression threads (default: `0` = all available CPU cores)

## Label Reference

| Label | Values | Description |
|-------|--------|-------------|
| `backup.enable` | `true` | Enable backup for this container |
| `backup.volume-path.<name>` | `/path/to/dir` | Backup a directory (can have multiple). Use for file backups or physical database backups. |
| `backup.database.pg_dumpall` | `true` | PostgreSQL logical backup (requires env vars) |
| `backup.database.mariadb-dump` | `true` | MariaDB logical backup (requires env vars) |

## Security Considerations

- **Docker Socket Access**: The backup container requires access to `/var/run/docker.sock`, which grants significant control over the Docker daemon. Only run in trusted environments.
- **Credentials**: The backup process uses temporary credential files (`.pgpass` for PostgreSQL, `.my.cnf` for MariaDB) inside target containers that are created with restrictive permissions (600) and deleted after use. Credentials are never passed via process arguments to prevent exposure in process listings.
- **Password Handling**: Database passwords are read from container environment variables. Use Docker secrets or env files for sensitive data. Never hardcode credentials in compose files.
- **Network Isolation**: For logical database backups (`pg_dumpall`, `mariadb-dump`), the backup sidecar uses `docker exec` to run dump commands directly inside the target containers, so no network connectivity between the sidecar and application stacks is required. The sidecar only needs network access to your S3 endpoint for uploading backups.
- **Backup Integrity**: All compressed archives are automatically verified for integrity using `zstd -t` before upload.
- **Error Isolation**: Each stack is processed independently. If one stack's backup fails, other stacks will still be backed up successfully.

## Troubleshooting

### No backups are running
- Check that at least one container in a compose stack has `backup.enable=true`
- Verify the cron schedule with `docker exec <backup-container> crontab -l`
- Check logs: `docker logs <backup-container>`

### Database backup fails
- Ensure the container has the correct environment variables (POSTGRES_*, MYSQL_*, MARIADB_*)
- For PostgreSQL, the backup runs `pg_dumpall` inside the container using `docker exec` and a temporary `.pgpass` file
- For MariaDB, the backup runs `mariadb-dump` inside the container using `docker exec` and a temporary `.my.cnf` file
- Check the error logs in the backup archive if the dump command fails

### Upload to S3 fails
- Verify S3 credentials and bucket permissions
- Check that the S3_BUCKET_URL format is correct
- Ensure the backup container has network access to S3

### Disk space issues
- The backup process requires at least 1GB of free disk space in `/tmp`
- Monitor disk usage: `df -h`
- Consider cleaning old temporary files or increasing disk space

### Containers not restarting after backup
- The cleanup function should automatically restart stopped containers
- Check logs for error messages during cleanup
- Manually restart: `docker compose -p <project-name> start`

## Backup Retention and S3 Lifecycle Policies

This backup solution does not automatically delete old backups. To prevent unlimited accumulation:

1. **Configure S3 Lifecycle Policies**: Set up automatic deletion or archival of old backups
   ```xml
   <!-- Example: Delete backups older than 30 days -->
   <LifecycleConfiguration>
     <Rule>
       <ID>DeleteOldBackups</ID>
       <Status>Enabled</Status>
       <Prefix>backup-</Prefix>
       <Expiration>
         <Days>30</Days>
       </Expiration>
     </Rule>
   </LifecycleConfiguration>
   ```

2. **Monitor S3 costs**: Regularly review your S3 storage costs and adjust retention as needed

## Best Practices

### Password Management
- **Use Docker secrets** for production environments instead of environment variables
- **Use strong passwords** for database credentials
- **Rotate credentials** regularly and update both the application and environment variables

### Backup Scheduling
- **Schedule during low-traffic periods** (default 2 AM is usually good)
- **Monitor backup duration** to ensure it completes before business hours
- **Stagger backups** if you have multiple hosts to reduce S3 API pressure

### Resource Management
- **Set `ZSTD_THREADS`** to limit CPU usage during compression (e.g., `ZSTD_THREADS=2` on a 4-core system)
- **Monitor disk space** in `/tmp` - backups are created there temporarily
- **Size your volumes appropriately** - backup process needs space equal to uncompressed data

### Testing and Validation
- **Test restore procedures** regularly - a backup is only as good as your ability to restore it
- **Monitor backup logs** for warnings or errors
- **Verify backup sizes** - sudden changes may indicate issues
- **Check S3 upload success** by listing bucket contents periodically

### Security Hardening
- **Use IAM roles** with minimal required S3 permissions (PutObject on specific bucket)
- **Enable S3 bucket versioning** for additional protection
- **Use S3 bucket encryption** at rest
- **Restrict Docker socket access** - only run backup container in trusted environments
- **Audit labels regularly** - malicious labels could potentially be used for attacks

### Monitoring
- **Set up alerts** for backup failures (monitor exit code or logs)
- **Track backup sizes** over time to detect anomalies
- **Monitor S3 storage growth** to avoid unexpected costs
- **Log aggregation**: Send logs to a centralized logging system for easier analysis

## Migration from Old Backup System

If you're migrating from the old per-stack backup system:

1. Deploy the new backup sidecar container once per host
2. Remove backup containers from individual stacks
3. Update labels on your containers:
   - Change `backup.volumes=/path1|/path2` to:
     - `backup.volume-path.name1=/path1`
     - `backup.volume-path.name2=/path2`
   - Change `backup.db.service=db` to `backup.database.pg_dumpall=true`
4. Ensure required environment variables are set in containers (not in the backup sidecar)
