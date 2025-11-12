# Backup and restore

**v0.2.1** <!-- x-release-please-version -->

This repo contains two containers that can be used to backup and restore data from docker containers.

- [backup](./backup) - A container that can be used to backup data from a specified source directory (in containers) to a specified s3 bucket.
- [restore](./restore) - A container that can be used to restore data from a specified s3 bucket to a specified docker stack.