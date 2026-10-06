# Production runbook

One small Linux VPS. Kamal 2 deploys the image `ghcr.io/amitkssolanki/whatsapp-integration`
behind kamal-proxy (automatic Let's Encrypt). PostgreSQL 17 runs as a Kamal accessory on the
same host (named volume `whatsapp-integration-db-data`). One database; Solid Queue runs inside
Puma. Config: `config/deploy.yml`, `.kamal/secrets`. Placeholders to replace in `config/deploy.yml`:
`app_host` (`whatsapp-demo.example.com`) and `server_ip` (`203.0.113.10`).

All `kamal` commands run from your laptop in this repo (`alias kamal='bundle exec kamal'`; there is no
binstub), with the secrets exported (below).

## 1. Prerequisites (Amit provides)

| Item | Detail |
|---|---|
| VPS | Ubuntu 24.04 LTS, amd64, 2 GB RAM, public IPv4, ports 22/80/443 open. Your SSH public key on `root` (`ssh root@IP` works without a password). Docker is installed by `kamal setup`. |
| DNS | A record `HOST -> IP`, **DNS-only (grey cloud) on Cloudflare**. Proxied (orange) breaks the Let's Encrypt challenge that kamal-proxy performs. Check: `dig +short HOST` returns the VPS IP. |
| GHCR token | GitHub classic PAT with `write:packages` and `read:packages` (Settings > Developer settings). Kamal also logs the VPS into ghcr.io with it. |
| Config edit | Set the real `app_host` and `server_ip` in `config/deploy.yml`, commit. Kamal builds from the committed HEAD and refuses a dirty tree. |
| Secrets | See below. |

### Secrets

Keep them in a file outside the repo, `chmod 600`, and `source` it in the shell before any `kamal`
command. `.kamal/secrets` only references these names (no values).

```sh
# ~/.config/whatsapp-demo/secrets.env
export KAMAL_REGISTRY_PASSWORD=...   # the GHCR PAT
export SECRET_KEY_BASE=...           # bin/rails secret
export POSTGRES_PASSWORD=...         # openssl rand -hex 24 (used by the app AND the accessory)
export WHATSAPP_VERIFY_TOKEN=...     # any string you invent; typed again in Meta's webhook config
export ADMIN_USER=...                # you invent: operator UI Basic-auth user
export ADMIN_PASSWORD=...            # you invent: long and random
export WHATSAPP_TOKEN=...            # Meta: System User permanent access token
export WHATSAPP_PHONE_NUMBER_ID=...  # Meta: WhatsApp > API Setup
export WHATSAPP_BUSINESS_ACCOUNT_ID=...  # Meta: WhatsApp > API Setup
export WHATSAPP_APP_SECRET=...       # Meta: App Settings > Basic > App secret
export CATALOG_ID=...                # Meta: Commerce Manager > Catalog ID
```

The Meta values come from your Meta dashboards, which only you operate. The app refuses to boot
if any of `WHATSAPP_TOKEN, WHATSAPP_PHONE_NUMBER_ID, WHATSAPP_VERIFY_TOKEN, WHATSAPP_APP_SECRET,
ADMIN_USER, ADMIN_PASSWORD, APP_HOST` is missing, or if `WHATSAPP_ALLOW_UNSIGNED` is set.

## 2. First deploy

```sh
source ~/.config/whatsapp-demo/secrets.env
kamal config | head -20          # sanity check (prints secrets: do not paste it anywhere)
kamal setup                      # installs Docker, boots proxy + Postgres, builds, pushes, deploys
curl -i https://HOST/up              # 200
curl -s "https://HOST/webhooks/whatsapp?hub.mode=subscribe&hub.verify_token=$WHATSAPP_VERIFY_TOKEN&hub.challenge=ping"   # ping
```

Then, in Meta's dashboard (you): set callback URL `https://HOST/webhooks/whatsapp` and the same
verify token. First certificate issuance can take a minute; if `/up` fails on TLS, check
`kamal proxy logs` and that DNS is grey-cloud.

Install backups (once, on the VPS):

```sh
ssh root@IP 'mkdir -p /opt/whatsapp-integration/backup /var/backups/whatsapp-integration'
scp script/backup/pg_backup.sh script/backup/pg_restore.sh root@IP:/opt/whatsapp-integration/backup/
ssh root@IP 'chmod 700 /opt/whatsapp-integration/backup/*.sh'
```

Add to root's crontab (`ssh root@IP`, `crontab -e`). Nightly 02:17 UTC, 7 days kept locally; set
`HEARTBEAT_URL` (Healthchecks.io / Better Stack heartbeat) so a silent failure alerts you:

```cron
17 2 * * * HEARTBEAT_URL=https://hc-ping.com/YOUR-UUID /opt/whatsapp-integration/backup/pg_backup.sh >> /var/log/whatsapp-integration-backup.log 2>&1
```

**Weekly off-host copy** (the VPS disk is not a backup of the VPS). From your laptop, every week
(calendar reminder), or from any always-on machine:

```sh
rsync -a --ignore-existing root@IP:/var/backups/whatsapp-integration/ ~/backups/whatsapp-integration/
```

## 3. Routine operations

```sh
source ~/.config/whatsapp-demo/secrets.env
kamal deploy                     # commit first; zero-downtime swap; migrations run on boot (db:prepare)
kamal rollback VERSION           # VERSION = git sha; list with: kamal app containers
kamal logs                       # follow app logs (alias for app logs -f); JSON lines
kamal app logs --since 30m --grep ERROR
kamal app logs --grep REQUEST_ID # one request, by its request_id
kamal accessory logs db          # PostgreSQL
kamal proxy logs                 # TLS / routing
kamal console                    # Rails console;  kamal dbc = psql
kamal details                    # what is running
```

Migrations run when the new container boots, before traffic switches, so they must be
backward compatible with the previous release. A rollback does not undo migrations; if one
corrupted data, restore a backup (section 4).

### Rotating the Meta token

1. In Meta Business settings (you): generate a new System User token, then revoke the old one.
2. `export WHATSAPP_TOKEN=<new>` in `secrets.env`, `source` it.
3. `kamal redeploy --skip-push` (same commit as the running version; otherwise `kamal deploy`).
4. Confirm sending works from the operator UI. Same procedure for `WHATSAPP_APP_SECRET`
   (change it in Meta first, deploy immediately: signed webhooks fail until both match and are
   retried by Meta) and `WHATSAPP_VERIFY_TOKEN` (change in Meta's webhook config too).

### Uptime monitor

UptimeRobot or Better Stack: HTTPS monitor on `https://HOST/up`, 1-5 minute interval, alert to
your email/phone. Add a second heartbeat monitor for the nightly backup (`HEARTBEAT_URL` above).

## 4. Backup and restore

Dumps: `/var/backups/whatsapp-integration/whatsapp_integration_production_<UTC>.dump` (`pg_dump -Fc`).

### Restore drill (non-destructive, scratch database)

```sh
ssh root@IP
/opt/whatsapp-integration/backup/pg_backup.sh                               # fresh dump, exit 0
LATEST=$(ls -t /var/backups/whatsapp-integration/*.dump | head -1)
/opt/whatsapp-integration/backup/pg_restore.sh "$LATEST" restore_test       # prints tables + latest migration
for db in whatsapp_integration_production restore_test; do
  docker exec whatsapp-integration-db psql -U whatsapp_integration -d $db -qAt \
    -c "select '$db', (select count(*) from orders), (select count(*) from messages)"
done                                                                         # counts match (live may be newer)
docker exec whatsapp-integration-db psql -U whatsapp_integration -d postgres -c 'DROP DATABASE restore_test'
```

### Restore over the live database (disaster)

`pg_restore.sh` never writes to the live database: it restores the dump into a **new** database
(`--single-transaction`, so a failed restore leaves nothing behind, and it refuses a name that
already exists unless `--replace-scratch`). Putting the restored copy into service is a separate,
deliberate, manual swap, done with the app stopped. Pick the restored name once, for example
`whatsapp_integration_restored` (the same name in every step).

```sh
# 1. Restore into a new database (the app keeps running; the live DB is untouched).
ssh -t root@IP /opt/whatsapp-integration/backup/pg_restore.sh DUMP whatsapp_integration_restored
#    Check the printed table count and latest migration, then compare counts with the live DB
#    as in the drill above. Stop here if anything looks wrong: nothing has changed.

# 2. Stop the app (laptop). Nothing may be connected to the live database during the rename.
kamal app stop
ssh root@IP "docker exec whatsapp-integration-db psql -U whatsapp_integration -d postgres -qAt \
  -c \"SELECT count(*) FROM pg_stat_activity WHERE datname = 'whatsapp_integration_production'\""   # must print 0

# 3. Swap by renaming (one psql session, in the postgres database). The old database is kept.
ssh root@IP "docker exec -i whatsapp-integration-db psql -U whatsapp_integration -d postgres -v ON_ERROR_STOP=1 <<'SQL'
ALTER DATABASE whatsapp_integration_production RENAME TO whatsapp_integration_production_replaced;
ALTER DATABASE whatsapp_integration_restored RENAME TO whatsapp_integration_production;
SQL"

# 4. Start the app and verify (laptop). Boot runs db:prepare, which applies any migration the
#    dump predates; the app uses Meta's retries to catch up on webhooks it missed while stopped.
kamal app boot
curl -i https://HOST/up
```

Undo (if the restored copy is wrong): `kamal app stop`, repeat step 3 with the two names swapped
back (`..._production` to `..._restored`, then `..._production_replaced` to `..._production`),
`kamal app boot`. Drop `whatsapp_integration_production_replaced` by hand only after the restored
database has been in service long enough that you would not want the old one back
(`DROP DATABASE whatsapp_integration_production_replaced`).

Messages Meta delivered between the dump and the outage are not in the dump. Meta retries
undelivered webhooks for a while; anything older is lost, and the Health page and the delivery
list show what the restored database does contain. Send-side rows (`unknown`, `pending`) from
before the dump are recovered by the stall sweeper and Meta's status webhooks, never resent blindly.

New VPS after total loss: provision, update `server_ip` and DNS, `kamal setup`, `scp` the
latest off-host dump to the VPS, then follow the four steps above (the fresh database created by
`kamal setup` is the "live" one that gets replaced).

### Before the operating period (checklist)

- [ ] Restore drill above completed on the real VPS with a real dump, counts compared.
- [ ] Cron line installed; one nightly dump seen in `/var/backups/whatsapp-integration/`.
- [ ] Heartbeat monitor alerting on a missed backup (stop cron once to prove it).
- [ ] Off-host copy performed once; the copied dump restored on your laptop or the VPS.
- [ ] `/up` monitor alerting (pause the app once to prove it).

## 5. Cost (approximate; check current prices)

VPS 2 GB (Hetzner/DigitalOcean/Vultr class): about USD 5-12 per month. Domain: already owned.
GHCR, Let's Encrypt, UptimeRobot/Better Stack free tiers, Healthchecks.io free tier: 0.
Total: roughly USD 5-12 per month. Meta charges conversation fees separately.

## 6. Intentionally not included

Kubernetes or any orchestrator; multiple hosts or zero-downtime across hosts; a managed
database (the accessory's single volume plus dumps is the whole durability story); a staging
environment (`kamal config` plus the restore drill is the pre-flight); Redis or a cache store;
email; a CDN or Cloudflare proxy; log shipping (Docker rotates 5 x 10 MB per container).
