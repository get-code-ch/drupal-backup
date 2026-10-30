#!/usr/bin/env bash
# 2 - Copy a local backup to S3-compatible object storage, then apply retention.
#
# Usage: 2-upload-s3.sh [-s SITE | -c CONFIG_FILE] [BACKUP_NAME]
#   BACKUP_NAME  directory in $BACKUP_DIR (e.g. 20261030-023000).
#                Default: the most recent local backup.

source "$(dirname "$(readlink -f "$0")")/lib/common.sh" "$@"
set -- "${ARGS[@]}"

require_cmd sha256sum flock
setup_rclone
acquire_lock

NAME="${1:-$(latest_local_backup)}"
[[ -n "$NAME" ]] || die "no local backup in $BACKUP_DIR"
SRC="$BACKUP_DIR/$NAME"
[[ -d "$SRC" ]] || die "backup not found: $SRC"

verify_backup "$SRC"

log "=== Uploading $NAME to $S3_REMOTE/$NAME ==="
rclone copy "$SRC" "$S3_REMOTE/$NAME" --s3-upload-concurrency 4 --retries 5 --stats-one-line --stats 1m
rclone check "$SRC" "$S3_REMOTE/$NAME" --one-way --size-only
log "Upload complete and verified."

# --- S3 retention ------------------------------------------------------------
if (( S3_RETENTION_DAYS > 0 )); then
  limit="$(date -d "-$S3_RETENTION_DAYS days" '+%Y%m%d-%H%M%S')"
  rclone lsf --dirs-only "$S3_REMOTE" | sed 's#/$##' | grep -E '^[0-9]{8}-[0-9]{6}$' \
    | while read -r dir; do
        if [[ "$dir" < "$limit" ]]; then
          log "Removing old S3 backup: $dir"
          rclone purge "$S3_REMOTE/$dir"
        fi
      done || true
fi
