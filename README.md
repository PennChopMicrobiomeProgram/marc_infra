# marc_infra

Podman Compose stack for running the `marc_web` application with both production and development deployments behind a single NGINX load balancer.

## Layout

```
marc_infra/
├── data/                 # local copy of the SQLite database (synced from NFS)
├── dev/                  # optional context for dev image build
├── prod/                 # optional context for prod image build
├── nginx/
│   └── nginx.conf        # reverse proxy + load balancer configuration
├── scripts/              # cron + sync helper scripts
└── docker-compose.yaml   # podman-compose entrypoint
```

## Services

- **db-sync**: copies the NFS-hosted SQLite database to `./data/marc.sqlite` on startup and every 10 minutes using cron while writing the latest sync timestamp.
- **marc-web-prod-a / marc-web-prod-b**: two production instances of `marc_web` sharing the `appnet` bridge network and reading the local SQLite database read-only.
- **marc-web-dev-a / marc-web-dev-b**: two development instances of `marc_web` on the same network, also mounting the SQLite database read-only.
- **nginx**: reverse proxy and path-based load balancer, exposing port `8080` on the host. Traffic to `/prod/` is sent to the production pool; `/dev/` is sent to the development pool.

Images default to `ctbushman/marc_web:0.3.5`. Swap images or add build contexts in `prod/` and `dev/` if you need to build locally.

## Database mounting and sync

The `marc_web` containers expect the SQLite database at `/data/marc.sqlite` mounted read-only along with a `/data/last_sync.txt` file containing the timestamp of the most recent successful sync. The `db-sync` service manages a writable copy at `./data/marc.sqlite` and keeps it synced from the NFS export.

- Set `MARC_NFS_DB_PATH` to the SQLite file on your NFS mount (defaults to `/mnt/isilon/marc_genomics/marc_web_db_RO/marc.sqlite`).
- On startup, `db-sync` copies the NFS file into `./data/marc.sqlite`, writes the timestamp of the successful sync to `./data/last_sync.txt`, and then runs cron every 10 minutes to refresh both files.
- The `MARC_DB_URL` environment variable for each `marc_web` container is set to `sqlite:////data/marc.sqlite` and `MARC_DB_LAST_SYNC` to `/data/last_sync.txt`.
- The sync timestamp is stored as `YYYY/MM/DD HH:MM:SS` in `/data/last_sync.txt`.

If the source database is unavailable or unreadable, `db-sync` will log an error and stop to avoid mounting a stale copy.

## Usage

Start the stack with Podman Compose:

```bash
export OPENAI_API_KEY=your_api_key_here
podman-compose up -d
```

Then visit:

- http://localhost:8080/ → simple nginx landing page confirming the proxy is reachable with links to each pool
- http://localhost:8080/prod/ → load-balanced across `marc-web-prod-a` and `marc-web-prod-b`
- http://localhost:8080/dev/ → load-balanced across `marc-web-dev-a` and `marc-web-dev-b`
- http://localhost:8080/health → nginx health endpoint returning JSON for quick checks

To tear down:

```bash
podman-compose down
```

## Logging

- Container stdout/stderr for each `marc_web` instance is written to the host at `/var/log/marc/<service>.log` using Podman's `k8s-file` log driver. NGINX logs also land in `/var/log/marc`.
- A dedicated `marc-logrotate` service runs hourly log rotation with compression for any `/var/log/marc/*.log` files to keep them bounded (14 backups, 50 MB max size before rotation).
- Ensure the log directory exists on the host before starting the stack:

```bash
sudo mkdir -p /var/log/marc
sudo chown $USER /var/log/marc
```
