#!/usr/bin/env bash
# 1 - Local backup of a Drupal site (database + files).
#
# Usage: 1-backup.sh [-s SITE | -c CONFIG_FILE]
#
# Creates $BACKUP_DIR/YYYYMMDD-HHMMSS/ containing:
#   database.sql.gz  database dump (cache tables without data)
#   files.tar.gz     whole project tree (code, vendor, files, private), minus EXCLUDES
#   INFO.txt         metadata (source path, Drupal and PHP versions, composer.lock hash)
#   SHA256SUMS       checksums

source "$(dirname "$(readlink -f "$0")")/lib/common.sh" "$@"
set -- "${ARGS[@]}"
(( $# == 0 )) || die "unexpected argument: $1 (see --help)"

require_cmd tar gzip sha256sum flock
acquire_lock
[[ -x "$DRUSH" ]] || die "drush not found: $DRUSH"

NAME="$(date '+%Y%m%d-%H%M%S')"
DEST="$BACKUP_DIR/$NAME"
WORK="$BACKUP_DIR/.$NAME.partial"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

log "=== Backup of $SITE_NAME -> $DEST ==="

# --- Database ----------------------------------------------------------------
log "Dumping database..."
drush sql:dump --structure-tables-key=common --extra-dump="--no-tablespaces" \
  | gzip -6 >"$WORK/database.sql.gz"
gzip -t "$WORK/database.sql.gz"
log "Database: $(du -h "$WORK/database.sql.gz" | cut -f1)"

# --- Files -------------------------------------------------------------------
log "Archiving $SITE_ROOT..."
exclude_args=()
for e in "${EXCLUDES[@]}"; do exclude_args+=("--exclude=$e"); done
rc=0
tar -C "$SITE_ROOT" --warning=no-file-changed "${exclude_args[@]}" \
  -czf "$WORK/files.tar.gz" . || rc=$?
# Exit code 1 = some files changed while being read: acceptable.
(( rc <= 1 )) || die "tar failed (exit code $rc)"
log "Files: $(du -h "$WORK/files.tar.gz" | cut -f1)"

# --- Metadata ----------------------------------------------------------------
docroot="$(docroot_of "$SITE_ROOT")"
{
  echo "site=$SITE_NAME"
  echo "date=$(date -Iseconds)"
  echo "host=$(hostname -f 2>/dev/null || hostname)"
  echo "site_root=$SITE_ROOT"
  echo "docroot=${docroot#"$SITE_ROOT"}"
  echo "drupal=$(drush status --field=drupal-version 2>/dev/null || echo '?')"
  echo "php=$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo '?')"
  if [[ -f "$SITE_ROOT/composer.lock" ]]; then
    echo "composer_lock_sha256=$(sha256sum "$SITE_ROOT/composer.lock" | cut -d' ' -f1)"
  fi
} >"$WORK/INFO.txt"

(cd "$WORK" && sha256sum database.sql.gz files.tar.gz INFO.txt >SHA256SUMS)
mv "$WORK" "$DEST"
trap - EXIT
log "Backup complete: $DEST ($(du -sh "$DEST" | cut -f1))"

# --- Local retention ---------------------------------------------------------
if (( LOCAL_RETENTION_DAYS > 0 )); then
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*-[0-9]*' \
    -mtime +"$LOCAL_RETENTION_DAYS" -print0 \
    | while IFS= read -r -d '' old; do
        log "Removing old local backup: $old"
        rm -rf -- "$old"
      done
fi
