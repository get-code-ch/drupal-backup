#!/usr/bin/env bash
# Clone a Drupal site into a new environment on this server, e.g.
# ev-euterpe.ch -> staging.ev-euterpe.ch: new directory, new database and
# database user, new host name. Run it again to refresh the clone.
#
# Usage: clone.sh [-s SITE | -c CONFIG_FILE] (-t TARGET | --target-config FILE) [options]
#   -s / -c               source site
#   -t TARGET             target site: reads $CONFIG_DIR/TARGET.conf
#   --target-config FILE  target configuration file
#   --backup NAME|latest  clone this backup of the source instead of the live
#                         site (local, else downloaded from S3;
#                         latest = most recent local backup)
#   --yes                 do not ask for confirmation
#
# The target configuration is a normal site configuration (SITE_ROOT,
# BACKUP_DIR, ...) with the CLONE_* settings (see backup.conf.example).
# Without --backup, a fresh backup of the source is made first (backup.sh).
# The database and its user are created with CLONE_MYSQL (default: mysql as
# root) and a new password. The clone gets sites/default/settings.clone.php
# (database, trusted host, new hash_salt, staging safeguards), included at
# the end of its settings.php. An existing target is replaced (database
# included) only if it was created by clone.sh.

source "$(dirname "$(readlink -f "$0")")/lib/common.sh" "$@"
set -- "${ARGS[@]}"

TARGET_CONFIG="" BACKUP_NAME="" ASSUME_YES=0
while (( $# )); do
  case "$1" in
    -t|--target)     [[ $# -ge 2 ]] || die "$1 requires a site name"; TARGET_CONFIG="$CONFIG_DIR/$2.conf"; shift ;;
    --target-config) [[ $# -ge 2 ]] || die "$1 requires a file"; TARGET_CONFIG="$2"; shift ;;
    --backup)        [[ $# -ge 2 ]] || die "$1 requires a backup name"; BACKUP_NAME="$2"; shift ;;
    --yes|-y)        ASSUME_YES=1 ;;
    *)               die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done
[[ -n "$TARGET_CONFIG" ]] || die "no target: use -t TARGET or --target-config FILE (see --help)"
[[ "$(readlink -f "$TARGET_CONFIG")" != "$(readlink -f "$CONFIG_FILE")" ]] \
  || die "source and target are the same configuration: $CONFIG_FILE"
if [[ -n "$BACKUP_NAME" && "$BACKUP_NAME" != latest && ! "$BACKUP_NAME" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
  die "invalid backup name: $BACKUP_NAME (expected YYYYMMDD-HHMMSS or latest)"
fi

require_cmd tar gzip sha256sum flock

# Single-quoted PHP string.
php_quote() { local s="${1//\\/\\\\}"; printf "'%s'" "${s//\'/\\\'}"; }
# Random letters and digits (safe in SQL and PHP strings).
random_string() { head -c 96 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | cut -c "1-$1"; }

# --- Source copy -------------------------------------------------------------
if [[ -z "$BACKUP_NAME" ]]; then
  log "Fresh backup of $SITE_NAME..."
  "$SCRIPT_DIR/backup.sh" -c "$CONFIG_FILE" || die "backup of $SITE_NAME failed"
  BACKUP_NAME="$(latest_local_backup)"
elif [[ "$BACKUP_NAME" == latest ]]; then
  BACKUP_NAME="$(latest_local_backup)"
  [[ -n "$BACKUP_NAME" ]] || die "no local backup in $BACKUP_DIR (see download-s3.sh)"
elif [[ ! -d "$BACKUP_DIR/$BACKUP_NAME" ]]; then
  "$SCRIPT_DIR/download-s3.sh" -c "$CONFIG_FILE" "$BACKUP_NAME" || die "download of $BACKUP_NAME failed"
fi
# Keeps the local retention of the source from removing the backup meanwhile.
acquire_lock
SRC="$BACKUP_DIR/$BACKUP_NAME"
[[ -d "$SRC" ]] || die "backup not found: $SRC"
verify_backup "$SRC"
ORIG_ROOT="$(sed -n 's/^site_root=//p' "$SRC/INFO.txt")"
ORIG_ROOT="${ORIG_ROOT:-$SITE_ROOT}"

# Database of the source, if it runs on this server: the target must not use it.
SRC_DB="" SRC_DB_USER=""
if [[ -d "$SITE_ROOT" ]]; then
  SRC_DB="$(trap - ERR; drush status --field=db-name 2>/dev/null)" || SRC_DB=""
  SRC_DB_USER="$(trap - ERR; drush status --field=db-username 2>/dev/null)" || SRC_DB_USER=""
  [[ -n "$SRC_DB" ]] || warn "cannot read the database name of $SITE_NAME: make sure CLONE_DB_NAME is not the production one"
fi
SRC_SITE="$SITE_NAME" SRC_ROOT="$SITE_ROOT" SRC_BACKUP_DIR="$BACKUP_DIR"

# --- Target ------------------------------------------------------------------
load_config "$TARGET_CONFIG"
[[ -n "$CLONE_HOST" ]] || die "CLONE_HOST (host name of the clone) is not set in $CONFIG_FILE"
[[ "$CLONE_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid CLONE_HOST: $CLONE_HOST"
[[ "$SITE_ROOT" != "$SRC_ROOT" ]] || die "the target SITE_ROOT is the source one: $SITE_ROOT"
[[ "$BACKUP_DIR" != "$SRC_BACKUP_DIR" ]] || die "the target BACKUP_DIR is the source one: $BACKUP_DIR"
for v in CLONE_DB_NAME CLONE_DB_USER; do
  [[ "${!v}" =~ ^[A-Za-z0-9_]+$ ]] || die "$v may only contain letters, digits and _: ${!v}"
done
[[ "$CLONE_DB_GRANT_HOST" =~ ^[A-Za-z0-9._%-]+$ ]] || die "invalid CLONE_DB_GRANT_HOST: $CLONE_DB_GRANT_HOST"
[[ "$CLONE_DB_NAME" != "$SRC_DB" ]] || die "CLONE_DB_NAME is the database of the source: $CLONE_DB_NAME"
[[ "$CLONE_DB_USER" != "$SRC_DB_USER" ]] || die "CLONE_DB_USER is the database user of the source: $CLONE_DB_USER"
require_cmd "${CLONE_MYSQL[0]}"
acquire_lock

mysql_admin() { "${CLONE_MYSQL[@]}" -N -B; }
mysql_admin <<<'SELECT 1' >/dev/null \
  || die "cannot connect to the database server as administrator with: ${CLONE_MYSQL[*]} (see CLONE_MYSQL)"
DB_EXISTS="$(mysql_admin <<<"SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$CLONE_DB_NAME'")"
USER_EXISTS="$(mysql_admin <<<"SELECT COUNT(*) FROM mysql.user WHERE User = '$CLONE_DB_USER' AND Host = '$CLONE_DB_GRANT_HOST'")"

TARGET_EXISTS=0
if [[ -e "$SITE_ROOT" ]]; then
  [[ -f "$(docroot_of "$SITE_ROOT")/sites/default/settings.clone.php" ]] \
    || die "$SITE_ROOT exists and was not created by clone.sh: refusing to replace it"
  TARGET_EXISTS=1
else
  (( DB_EXISTS == 0 )) || die "database $CLONE_DB_NAME exists but $SITE_ROOT does not: refusing to drop it"
  (( USER_EXISTS == 0 )) || die "database user $CLONE_DB_USER@$CLONE_DB_GRANT_HOST exists but $SITE_ROOT does not: refusing to change its password"
fi

STAMP="$(date '+%Y%m%d-%H%M%S')"
NEW_ROOT="$SITE_ROOT.clone-$STAMP"
OLD_ROOT="$SITE_ROOT.before-clone-$STAMP"

echo
echo "Cloning $SRC_SITE, backup $BACKUP_NAME:"
sed 's/^/    /' "$SRC/INFO.txt"
echo "Target: $SITE_NAME"
if (( TARGET_EXISTS )); then
  echo "  - files: $SITE_ROOT will be REPLACED"
else
  echo "  - files: $SITE_ROOT will be created"
fi
if (( DB_EXISTS )); then
  echo "  - database: $CLONE_DB_NAME will be DROPPED and recreated"
else
  echo "  - database: $CLONE_DB_NAME will be created"
fi
echo "  - database user: $CLONE_DB_USER@$CLONE_DB_GRANT_HOST (new password)"
echo "  - host: $CLONE_HOST"
if (( CLONE_STAGING )); then
  echo "  - staging: no e-mail sent, robots.txt disallows everything${CLONE_UNINSTALL_MODULES[*]:+, uninstall ${CLONE_UNINSTALL_MODULES[*]}}"
fi
if (( ! ASSUME_YES )); then
  read -r -p "Type 'yes' to confirm: " answer
  [[ "$answer" == "yes" ]] || die "clone cancelled"
fi

log "=== Cloning $SRC_SITE ($BACKUP_NAME) into $SITE_ROOT ($CLONE_HOST) ==="

# --- Files -------------------------------------------------------------------
log "Extracting files into $NEW_ROOT..."
mkdir -p "$NEW_ROOT"
# Remove the partial tree on any failure (sites/default is read-only, hence chmod).
trap 'chmod -R u+w "$NEW_ROOT" 2>/dev/null; rm -rf "$NEW_ROOT"' EXIT
tar_opts=(-xzf "$SRC/files.tar.gz" -C "$NEW_ROOT")
(( EUID == 0 )) && tar_opts+=(--same-owner --same-permissions)
tar "${tar_opts[@]}" || die "extraction failed"
if [[ -n "$RESTORE_OWNER" ]]; then
  (( EUID == 0 )) || die "RESTORE_OWNER requires running as root"
  log "Setting owner $RESTORE_OWNER"
  chown -R "$RESTORE_OWNER" "$NEW_ROOT"
fi

new_doc="$(docroot_of "$NEW_ROOT")"
site_dir="$new_doc/sites/default"
[[ -f "$site_dir/settings.php" ]] || die "settings.php not found in the backup: $site_dir/settings.php"
others="$(find "$new_doc/sites" -mindepth 2 -maxdepth 2 -name settings.php ! -path "$site_dir/*")"
[[ -z "$others" ]] || warn "multisite: only sites/default is adapted, these still use the source settings: $others"

log "Writing $site_dir/settings.clone.php"
DB_PASS="$(random_string 32)"
grep -q '?>[[:space:]]*$' <(tail -c 100 "$site_dir/settings.php") \
  && die "settings.php ends with '?>': remove it in the source so that clone.sh can append to it"
site_mode="$(stat -c %a "$site_dir")"
settings_mode="$(stat -c %a "$site_dir/settings.php")"
chmod u+w "$site_dir" "$site_dir/settings.php"
{
  cat <<EOF
<?php

/**
 * @file
 * Settings of this clone, written by drupal-backup clone.sh and rewritten on
 * each clone: do not edit, put local changes in another file.
 *
 * Source: $SRC_SITE, backup $BACKUP_NAME, cloned on $(date '+%F %T').
 */

\$databases['default']['default']['database'] = $(php_quote "$CLONE_DB_NAME");
\$databases['default']['default']['username'] = $(php_quote "$CLONE_DB_USER");
\$databases['default']['default']['password'] = $(php_quote "$DB_PASS");
\$databases['default']['default']['host'] = $(php_quote "$CLONE_DB_HOST");

\$settings['trusted_host_patterns'] = ['^' . preg_quote($(php_quote "$CLONE_HOST")) . '\$'];
\$settings['hash_salt'] = $(php_quote "$(random_string 64)");

// Absolute paths into the source tree now point into the clone.
\$clone_source_root = $(php_quote "$ORIG_ROOT");
foreach (['file_private_path', 'file_temp_path', 'config_sync_directory'] as \$key) {
  if (isset(\$settings[\$key]) && (\$settings[\$key] === \$clone_source_root || strpos(\$settings[\$key], \$clone_source_root . '/') === 0)) {
    \$settings[\$key] = $(php_quote "$SITE_ROOT") . substr(\$settings[\$key], strlen(\$clone_source_root));
  }
}
EOF
  if (( CLONE_STAGING )); then
    cat <<'EOF'

// Staging safeguards (CLONE_STAGING=1).
// No e-mail is sent: messages are only kept in the state (test mail collector).
$config['system.mail']['interface']['default'] = 'test_mail_collector';
$config['mailsystem.settings']['defaults']['sender'] = 'test_mail_collector';
$config['smtp.settings']['smtp_on'] = FALSE;
// Not indexed by search engines (robots.txt is replaced as well).
$config['robotstxt.settings']['content'] = "User-agent: *\nDisallow: /\n";
EOF
  fi
} >"$site_dir/settings.clone.php"
chown --reference="$site_dir/settings.php" "$site_dir/settings.clone.php"
cat >>"$site_dir/settings.php" <<'EOF'

// Added by drupal-backup clone.sh: settings of this clone.
include $app_root . '/' . $site_path . '/settings.clone.php';
EOF
chmod "$settings_mode" "$site_dir/settings.php" "$site_dir/settings.clone.php"
chmod "$site_mode" "$site_dir"

if (( CLONE_STAGING )); then
  if [[ ! -f "$new_doc/robots.txt" ]]; then
    touch "$new_doc/robots.txt"
    chown --reference="$new_doc/index.php" "$new_doc/robots.txt"
    chmod --reference="$new_doc/index.php" "$new_doc/robots.txt"
  fi
  printf 'User-agent: *\nDisallow: /\n' >"$new_doc/robots.txt"
fi

# Absolute paths of the source left in the settings (other than the ones above).
hits="$(grep -HnF "$ORIG_ROOT" "$site_dir"/settings*.php 2>/dev/null \
  | grep -vE ':[0-9]+:\s*(#|\*|//)|file_private_path|file_temp_path|config_sync_directory|clone_source_root' || true)"
if [[ -n "$hits" ]]; then
  warn "the settings still reference the source path $ORIG_ROOT, check these lines:"
  echo "$hits" | sed "s#^$NEW_ROOT#$SITE_ROOT#; s/^/    /" >&2
fi

# --- Database ----------------------------------------------------------------
log "Creating database $CLONE_DB_NAME and user $CLONE_DB_USER@$CLONE_DB_GRANT_HOST..."
user="'$CLONE_DB_USER'@'$CLONE_DB_GRANT_HOST'"
{
  (( DB_EXISTS )) && echo "DROP DATABASE \`$CLONE_DB_NAME\`;"
  cat <<EOF
CREATE DATABASE \`$CLONE_DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS $user IDENTIFIED BY '$DB_PASS';
ALTER USER $user IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$CLONE_DB_NAME\`.* TO $user;
EOF
} | mysql_admin

# --- Switch ------------------------------------------------------------------
if (( TARGET_EXISTS )); then
  log "Switching: $SITE_ROOT -> $OLD_ROOT"
  mv "$SITE_ROOT" "$OLD_ROOT"
fi
mv "$NEW_ROOT" "$SITE_ROOT"
trap - EXIT
log "Files cloned in $SITE_ROOT"

log "Importing database..."
gzip -dc "$SRC/database.sql.gz" | drush sql:cli
log "Rebuilding caches..."
drush cache:rebuild

if (( CLONE_STAGING && ${#CLONE_UNINSTALL_MODULES[@]} )); then
  enabled="$(drush pm:list --type=module --status=enabled --field=name)"
  to_uninstall=()
  for m in "${CLONE_UNINSTALL_MODULES[@]}"; do
    if grep -qxF "$m" <<<"$enabled"; then
      to_uninstall+=("$m")
    else
      log "Module $m is not enabled, skipped"
    fi
  done
  if (( ${#to_uninstall[@]} )); then
    log "Uninstalling: ${to_uninstall[*]}"
    drush pm:uninstall -y "${to_uninstall[@]}"
  fi
fi
drush state:set system.maintenance_mode 0 --input-format=integer

# Directories outside the clone would be shared with the source.
for key in file_private_path config_sync_directory; do
  val="$(drush php:eval "echo \Drupal\Core\Site\Settings::get('$key', '');")"
  if [[ "$val" == /* && "$val" != "$SITE_ROOT"/* ]]; then
    warn "$key is outside the clone: $val (shared with the source?), override it in another settings file"
  fi
done
drush status --fields=drupal-version,db-status,bootstrap

if (( TARGET_EXISTS )); then
  log "Removing the previous clone $OLD_ROOT"
  chmod -R u+w "$OLD_ROOT"
  rm -rf "$OLD_ROOT"
fi

log "Clone complete: $SITE_ROOT, database $CLONE_DB_NAME"
log "Web server: serve $CLONE_HOST from $(docroot_of "$SITE_ROOT") (virtual host, DNS, TLS)"
exit 0
