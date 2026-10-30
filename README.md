# drupal-backup

Scripts Bash pour sauvegarder un site Drupal géré avec Composer (fichiers +
base de données), copier les sauvegardes sur un stockage objet compatible S3
(Hetzner, Cloudflare R2, AWS, Wasabi, MinIO…), les récupérer et restaurer le site — sur le
même serveur ou sur un nouveau (reprise après sinistre, migration).

| Script | Rôle |
|---|---|
| `1-backup.sh` | Sauvegarde locale : base (`drush sql:dump`) + fichiers (`tar`) |
| `2-upload-s3.sh [NOM]` | Envoi d'une sauvegarde sur S3, vérification, rétention |
| `3-download-s3.sh [--list \| NOM \| latest]` | Récupération d'une sauvegarde depuis S3 |
| `4-restore.sh [options] [NOM]` | Restauration des fichiers et/ou de la base |

Options communes : `-s SITE` (lit `/etc/drupal-backup/SITE.conf`),
`-c FICHIER` (autre fichier de configuration), `-h` (aide).
Sans `-s`/`-c`, le seul fichier `.conf` de `/etc/drupal-backup` est utilisé.
Sans `NOM`, la sauvegarde la plus récente est prise.

## Prérequis

- bash, tar, gzip, coreutils, util-linux (`flock`, `runuser`)
- Drush installé par Composer dans le projet (`vendor/bin/drush`)
- client MySQL/MariaDB (`mysqldump`, `mysql`), utilisé par Drush
- [rclone](https://rclone.org) pour S3 : `sudo apt install rclone`

## Installation

```bash
sudo git clone https://github.com/get-code-ch/drupal-backup.git /opt/drupal-backup
```

Une configuration par site, hors du dépôt, lisible par root uniquement :

```bash
sudo install -d -m 700 /etc/drupal-backup
```

```bash
sudo install -m 600 /opt/drupal-backup/backup.conf.example /etc/drupal-backup/monsite.conf
```

```bash
sudo nano /etc/drupal-backup/monsite.conf
```

À renseigner au minimum : `SITE_NAME`, `SITE_ROOT`, `BACKUP_DIR`, `EXCLUDES`,
et pour S3 `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET`, `S3_ACCESS_KEY`,
`S3_SECRET_KEY`. Le bucket doit exister. Pour Hetzner : console →
Object Storage → *Manage credentials*. Pour Cloudflare R2 : `S3_PROVIDER="Cloudflare"`,
`S3_ENDPOINT="https://<account_id>.r2.cloudflarestorage.com"`, `S3_REGION="auto"`,
clés via R2 → *Manage API tokens* (permission *Object Read & Write* sur le bucket).

Test de la connexion S3 :

```bash
sudo /opt/drupal-backup/3-download-s3.sh -s monsite --list
```

Les scripts doivent tourner **en root** : la configuration n'est lisible que par
root, certains fichiers du site peuvent ne pas être lisibles par d'autres
utilisateurs, et `tar` conserve les propriétaires à la restauration. Drush est
exécuté sous `SITE_USER` (par défaut le propriétaire de `SITE_ROOT`).

## Contenu d'une sauvegarde

`$BACKUP_DIR/AAAAMMJJ-HHMMSS/` :

- `database.sql.gz` – dump complet ; les tables de cache, sessions et watchdog
  sont sauvegardées sans données (`--structure-tables-key=common`) ;
- `files.tar.gz` – toute l'arborescence de `SITE_ROOT` (code, `vendor/`,
  `composer.json/.lock`, fichiers publics et privés, `settings.php`), sauf `EXCLUDES` ;
- `INFO.txt` – chemin d'origine, date, serveur, versions Drupal et PHP, empreinte du `composer.lock` ;
- `SHA256SUMS` – vérifié avant l'envoi, après le téléchargement et avant la restauration.

## Sauvegarde automatique (cron)

`sudo crontab -e` :

```cron
# Tous les jours à 02h30 : sauvegarde locale puis envoi sur S3
30 2 * * * /opt/drupal-backup/1-backup.sh -s monsite >/dev/null && /opt/drupal-backup/2-upload-s3.sh -s monsite >/dev/null
# Un second site, un quart d'heure plus tard
45 2 * * * /opt/drupal-backup/1-backup.sh -s autresite >/dev/null && /opt/drupal-backup/2-upload-s3.sh -s autresite >/dev/null
```

Le détail est écrit dans `LOG_FILE` (par défaut `$BACKUP_DIR/backup.log`) ; les
erreurs sortent sur stderr et cron les envoie par e-mail si `MAILTO` est défini.
Rétention : `LOCAL_RETENTION_DAYS` et `S3_RETENTION_DAYS`.

## Restauration sur le même serveur

```bash
sudo /opt/drupal-backup/3-download-s3.sh -s monsite --list
```

```bash
sudo /opt/drupal-backup/3-download-s3.sh -s monsite 20261030-023000
```

```bash
sudo /opt/drupal-backup/4-restore.sh -s monsite 20261030-023000
```

Le script vérifie les sommes de contrôle, demande de taper `yes`, puis :

1. dumpe la base actuelle dans `$BACKUP_DIR/before-restore-<date>.sql.gz` ;
2. extrait l'archive à côté du site, passe le site en maintenance et bascule :
   l'ancien dossier devient `SITE_ROOT.before-restore-<date>` ;
3. vide la base (`drush sql:drop`) et importe le dump ;
4. `drush cache:rebuild` (+ `drush updatedb` avec `--updb`) et fin de la maintenance.

Options :

| Option | Usage |
|---|---|
| `--db-only` | base seule (ex. contenu supprimé par erreur) |
| `--files-only` | fichiers seuls (ex. `composer update` raté) |
| `--keep-settings` | garde les `settings*.php` / `services.yml` actuels |
| `--updb` | lance `drush updatedb` après la restauration |
| `--yes` | pas de confirmation |

Une fois le site vérifié, supprimer l'ancienne arborescence (`sites/default` est
en lecture seule, d'où le `chmod`) :

```bash
sudo chmod -R u+w /var/www/monsite.before-restore-<date> && sudo rm -rf /var/www/monsite.before-restore-<date>
```

## Migration ou reprise sur un nouveau serveur

1. Installer le serveur web, PHP (mêmes version et extensions que dans `INFO.txt`),
   MariaDB/MySQL et rclone.
2. Créer la base de données et l'utilisateur. Le plus simple est de reprendre
   les identifiants du `settings.php` d'origine ; sinon il faudra corriger
   `settings.php` à l'étape 5.
3. Cloner ce dépôt et créer `/etc/drupal-backup/monsite.conf` (mêmes
   paramètres S3 que sur l'ancien serveur ; `SITE_ROOT` peut être différent).
   Si les utilisateurs système diffèrent, définir `RESTORE_OWNER`
   (ex. `www-data:www-data`).
4. Récupérer la sauvegarde :

   ```bash
   sudo /opt/drupal-backup/3-download-s3.sh -s monsite latest
   ```

5. Restaurer les fichiers seuls :

   ```bash
   sudo /opt/drupal-backup/4-restore.sh -s monsite --files-only
   ```

   Si `SITE_ROOT` est différent de celui d'origine, le script affiche les lignes
   de `settings.php` qui contiennent encore l'ancien chemin (ex.
   `file_private_path`, `file_temp_path`). Adapter `settings.php` (chemins,
   identifiants de la base, `trusted_host_patterns`).
6. Restaurer la base :

   ```bash
   sudo /opt/drupal-backup/4-restore.sh -s monsite --db-only
   ```

7. Configurer le virtual host (racine = docroot du site), le DNS et le
   certificat TLS, puis vérifier le site.

Si les identifiants de la base sont identiques, les étapes 5 et 6 peuvent se
faire en une seule commande, sans `--files-only` ni `--db-only`.

## Sécurité

- Les archives contiennent `settings.php` (mot de passe de la base,
  `hash_salt`) : le bucket doit rester privé (les objets sont envoyés avec
  l'ACL `private`) et `BACKUP_DIR` n'est lisible que par root (`umask 077`).
- Les vraies configurations restent dans `/etc/drupal-backup` ; le
  `.gitignore` empêche de committer un fichier `*.conf`.

## Réalisation

Ce projet a été réalisé par l'IA — Claude (Anthropic), via Claude Code — à la
demande de Claude Débieux, qui l'a dirigé, relu et testé en production. Le
fichier [AGENTS.md](AGENTS.md) résume le contexte du projet pour qu'une IA
puisse le reprendre rapidement.

## Licence

MIT – voir [LICENSE](LICENSE).
