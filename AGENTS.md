# AGENTS.md — context for AI agents

Bash scripts that back up a Composer-managed Drupal site (database + whole
project tree) to local disk, copy the backups to S3-compatible object storage
with rclone, download them back and restore the site, on the same server or a
new one. User documentation: [README.md](README.md) (in French).

## Layout

| File | Role |
|---|---|
| `lib/common.sh` | Sourced first by every script with `"$@"`: strict mode, `-s/-c/-h` options (rest left in `ARGS`), config loading, defaults, helpers |
| `backup.sh` | `drush sql:dump` + `tar` of `SITE_ROOT` into `$BACKUP_DIR/YYYYMMDD-HHMMSS/`, `INFO.txt`, `SHA256SUMS`, local retention |
| `upload-s3.sh [NAME]` | `verify_backup`, `rclone copy` + `rclone check --size-only`, S3 retention |
| `download-s3.sh [--list\|NAME\|latest]` | List or download a backup, then `verify_backup` |
| `restore.sh [opts] [NAME]` | Restore files and/or DB; keeps `$SITE_ROOT.before-restore-<date>` and a DB dump as safety nets |
| `clone.sh -t TARGET [--backup NAME\|latest]` | Clone the source (`-s`) into a target site (own `.conf` with `CLONE_*`): fresh `backup.sh` or given backup, new DB + user via `CLONE_MYSQL`, `sites/default/settings.clone.php` included from `settings.php`, staging safeguards. With `CLONE_KEEP_SETTINGS=1` the target is an existing site (e.g. staging → prod): backed up first, keeps its settings/robots.txt/DB credentials, tables dropped and replaced, old tree kept. Private files: `file_private_path` is read on both live sites before any change; a private dir outside the source tree needs `CLONE_FILE_PRIVATE_PATH` (copied there), in keep mode the files are moved to the target's private location |
| `backup.conf.example` | Documented config template (one file per site) |

Helpers in `lib/common.sh`: `log`/`warn`/`die`, `load_config` (clears
`CONFIG_VARS`, sources a file, applies defaults; clone.sh calls it again for
the target), `acquire_lock` (flock on `$BACKUP_DIR/.lock`, new fd per call), `require_cmd`, `docroot_of`, `drush` (runs as
`SITE_USER` when root), `setup_rclone` (defines remote `s3:` and
`$S3_REMOTE`), `latest_local_backup`, `verify_backup`. Reuse them.

## Conventions

- `set -Eeuo pipefail`, `umask 077`, `trap ... ERR` calling `die`. Fail loudly;
  never hide a real error with `|| true` (only "no match" from `grep`).
- Code comments and log messages in English; README in French.
- Usage text = the comment block at the top of each script (`usage()` prints it).
- Config: one `/etc/drupal-backup/<site>.conf` (root, 600) per site, sourced as
  bash. Contains S3 credentials: never commit real `*.conf` (see `.gitignore`).
  New settings get a default in `load_config` (`lib/common.sh`), a name in
  `CONFIG_VARS` and a commented entry in `backup.conf.example`.
- rclone is configured only through `RCLONE_CONFIG_S3_*` environment variables;
  `RCLONE_CONFIG=""` (no rclone.conf, no "not found" notice).
- Backup names are `YYYYMMDD-HHMMSS` (sortable; retention compares strings).
- `SHA256SUMS` is checked before upload, after download and before restore.
- Scripts run as root (tar keeps owners, config readable by root only).

## Known pitfalls (learned in production)

- **Cloudflare R2 + old rclone (Debian 1.60)**: after each PUT, rclone sends
  `HEAD ?versionId=...`, which R2 answers with 501 NotImplemented although the
  upload succeeded. Fixed with `RCLONE_CONFIG_S3_NO_HEAD=true`; integrity is
  checked by `rclone check` in `upload-s3.sh`.
- **R2 EU jurisdiction buckets** need the `https://<account_id>.eu.r2.cloudflarestorage.com`
  endpoint and are invisible to the default Cloudflare API (bucket list).
- **R2 credentials**: Access Key ID = 32 chars, Secret Access Key = 64 chars.
  The 53-char "Token value" is for the Cloudflare API, not S3. A new token can
  return 403 for about a minute.
- R2 bucket names: lowercase letters, digits and hyphens only.
- `DOCROOT`: auto-detected as `web/` only if `web/index.php` exists; some sites
  have a `web/` folder without it (docroot = project root, set `DOCROOT="."`).

## Verifying a change

1. `bash -n` on every modified script; `shellcheck` if available.
2. Real run on a test site: `backup.sh -s SITE` → `upload-s3.sh -s SITE` →
   `download-s3.sh -s SITE --list`, then check exit codes.
3. Error paths: a config with wrong keys must make `--list` exit 1.
4. Never run `restore.sh`, or `clone.sh` with a production target, on a production site without the owner's explicit OK.

## Open items

- `upload-s3.sh` retention loop ends with `|| true`: an rclone listing error
  there is silently ignored (the upload itself is already verified).
- `download-s3.sh latest` prints the `die` message plus two extra
  "failed at line ..." lines from the ERR trap in the command substitution.
