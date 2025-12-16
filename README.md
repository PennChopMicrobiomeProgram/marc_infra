# marc_infra

Podman Compose stacks for running the `marc_web` application with separate production, development, database sync, and nginx layers that all attach to a shared Podman network.

## Layout

```
marc_infra/
├── data/                  # local copy of the SQLite database (synced from NFS)
├── db-sync/
│   └── docker-compose.yaml
├── dev/
│   └── docker-compose.yaml
├── prod/
│   └── docker-compose.yaml
├── nginx/
│   ├── docker-compose.yaml
│   ├── nginx.conf.template # reverse proxy + load balancer configuration template
│   └── nginx.conf         # generated from the template (gitignored)
├── scripts/               # cron + sync helper scripts
└── README.md
```

## Shared network

All stacks attach to the same Podman network so they can resolve one another by container name (e.g., `marc-web-prod-a`). Create it once before bringing up any stack:

```bash
podman network create marc_appnet
```

## Services by stack

- **db-sync** (`db-sync/docker-compose.yaml`): copies the NFS-hosted SQLite database to `./data/marc.sqlite` on startup and every 10 minutes using cron while writing the latest sync timestamp.
- **Production web** (`prod/docker-compose.yaml`): two production instances of `marc_web` reading the shared SQLite database read-only. Set `MARC_WEB_IMAGE` to change the image tag and `MARC_POOL` to change the pool name used for container/log naming.
- **Development web** (`dev/docker-compose.yaml`): single development instance of `marc_web` on the same network, also mounting the SQLite database read-only.
- **nginx** (`nginx/docker-compose.yaml`): reverse proxy and path-based load balancer, exposing port `8080` on the host. Traffic to `/prod/` is sent to the production pool; `/dev/` is sent to the development pool.

Images default to `ctbushman/marc_web:0.3.7`. Swap images or add build contexts in `prod/` and `dev/` if you need to build locally.

The nginx configuration is generated from the template using `envsubst`. Create it once before bringing up nginx for the first time:

```bash
MARC_PROD_POOL=prod MARC_DEV_POOL=dev envsubst '$MARC_PROD_POOL $MARC_DEV_POOL' < nginx/nginx.conf.template > nginx/nginx.conf
```

## Database mounting and sync

The `marc_web` containers expect the SQLite database at `/data/marc.sqlite` mounted read-only along with a `/data/last_sync.txt` file containing the timestamp of the most recent successful sync. The `db-sync` service manages a writable copy at `./data/marc.sqlite` and keeps it synced from the NFS export.

- Set `MARC_NFS_DB_PATH` to the SQLite file on your NFS mount (defaults to `/mnt/isilon/marc_genomics/marc_web_db_RO/marc.sqlite`).
- On startup, `db-sync` copies the NFS file into `./data/marc.sqlite`, writes the timestamp of the successful sync to `./data/last_sync.txt`, and then runs cron every 10 minutes to refresh both files.
- The `MARC_DB_URL` environment variable for each `marc_web` container is set to `sqlite:////data/marc.sqlite` and `MARC_DB_LAST_SYNC` to `/data/last_sync.txt`.
- The sync timestamp is stored as `YYYY/MM/DD HH:MM:SS` in `/data/last_sync.txt`.

If the source database is unavailable or unreadable, `db-sync` will log an error and stop to avoid mounting a stale copy.

## Usage

Export your API key and bring up each stack. Start `db-sync` first so the SQLite file is ready, then the web pools, and finally nginx:

```bash
export OPENAI_API_KEY=your_api_key_here
podman-compose -f db-sync/docker-compose.yaml up -d
podman-compose -f prod/docker-compose.yaml up -d
podman-compose -f dev/docker-compose.yaml up -d
podman-compose -f nginx/docker-compose.yaml up -d
```

Then visit:

- http://localhost:8080/ → simple nginx landing page confirming the proxy is reachable with links to each pool
- http://localhost:8080/prod/ → load-balanced across `marc-web-prod-a` and `marc-web-prod-b`
- http://localhost:8080/dev/ → served by `marc-web-dev-a`
- http://localhost:8080/health → nginx health endpoint returning JSON for quick checks

To tear down, run `podman-compose -f <stack>/docker-compose.yaml down` for each stack you started.

## Zero-downtime production upgrades

Use the helper script to perform a blue/green-style upgrade without dropping traffic. The script:

1. Starts a new production pool (with unique container names based on `MARC_POOL`) using the provided image tag.
2. Waits for both new containers to become healthy.
3. Ensures the `marc_appnet` network exists and that the new containers are attached to it alongside nginx.
4. Regenerates `nginx/nginx.conf` from `nginx/nginx.conf.template` to point production traffic at the new pool, reloads nginx, and verifies the proxy can reach each new backend.
5. Shuts down the previous production pool only after the new pool is reachable from nginx; otherwise it rolls back to the prior pool.

Example:

```bash
export OPENAI_API_KEY=your_api_key_here
./scripts/upgrade_prod_pool.sh --image ctbushman/marc_web:0.3.8
```

Options:

- `--pool`: Override the generated pool name (defaults to `prod-<image-tag>`).
- `--dev-pool`: Change the dev pool name nginx targets (defaults to `dev`).
- `--timeout`: How long to wait for the new containers to report healthy (default 300s).
- `--compose-bin`: Compose binary to use (defaults to `podman-compose`).

## Logging

- Container stdout/stderr for each service (`marc_web` instances, nginx, and `db-sync`) is written to the host at `/var/log/marc/<service>.log` using Podman's `k8s-file` log driver.
- Logs rotate automatically via the log driver once they reach 10 MB, keeping up to 5 files per service.
- Ensure the log directory exists on the host before starting the stacks:

```bash
sudo mkdir -p /var/log/marc
sudo chown $USER /var/log/marc
```

## TLS/SSL

Hopefully we can rely on IS to provide us certs or terminate SSL before it even reaches our VM.
