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

- **db-sync** (`db-sync/docker-compose.yaml`): copies the NFS-hosted SQLite database to `./data/marc.sqlite` on startup and every 10 minutes using cron while writing the latest sync timestamp. Requires `MARC_NFS_DB_PATH`.
- **Production web** (`prod/docker-compose.yaml`): two production instances of `marc_web` reading the shared SQLite database read-only. Requires `MARC_PROD_IMAGE`, `MARC_PROD_POOL`, and `OPENAI_API_KEY`.
- **Development web** (`dev/docker-compose.yaml`): single development instance of `marc_web` on the same network, also mounting the SQLite database read-only. Requires `MARC_DEV_IMAGE`, `MARC_DEV_POOL`, and `OPENAI_API_KEY`.
- **nginx** (`nginx/docker-compose.yaml`): reverse proxy and path-based load balancer, exposing port `8080` on the host. Traffic to `/prod/` is sent to the production pool; `/dev/` is sent to the development pool. Requires `nginx/nginx.conf` rendered with explicit pool names.

There are **no default values** baked into the compose files or helper scripts. You must explicitly provide all image tags, pool names, and secrets each time you start or upgrade the stack.

Generate the nginx configuration from the template using `envsubst` and explicit pool names:

```bash
MARC_PROD_POOL=prod-20240925 MARC_DEV_POOL=dev-20240925 envsubst '$MARC_PROD_POOL $MARC_DEV_POOL' < nginx/nginx.conf.template > nginx/nginx.conf
```

## Database mounting and sync

The `marc_web` containers expect the SQLite database at `/data/marc.sqlite` mounted read-only along with a `/data/last_sync.txt` file containing the timestamp of the most recent successful sync. The `db-sync` service manages a writable copy at `./data/marc.sqlite` and keeps it synced from the NFS export.

- Set `MARC_NFS_DB_PATH` to the SQLite file on your NFS mount.
- On startup, `db-sync` copies the NFS file into `./data/marc.sqlite`, writes the timestamp of the successful sync to `./data/last_sync.txt`, and then runs cron every 10 minutes to refresh both files.
- The `MARC_DB_URL` environment variable for each `marc_web` container is set to `sqlite:////data/marc.sqlite` and `MARC_DB_LAST_SYNC` to `/data/last_sync.txt`.
- The sync timestamp is stored as `YYYY/MM/DD HH:MM:SS` in `/data/last_sync.txt`.

If the source database is unavailable or unreadable, `db-sync` will log an error and stop to avoid mounting a stale copy.

## Usage

### One-shot bootstrap on a fresh machine

Use the helper script to provision everything (network, nginx config, and all stacks) with explicitly provided versions:

```bash
./scripts/bootstrap_full_stack.sh \
  --prod-image ctbushman/marc_web:1.0.0 \
  --prod-pool prod-20240925 \
  --dev-image ctbushman/marc_web:1.0.0-dev \
  --dev-pool dev-20240925 \
  --nfs-db-path /mnt/isilon/marc_genomics/marc_web_db_RO/marc.sqlite \
  --openai-key sk-... \
  --compose-bin podman-compose
```

The script has no defaults: every flag is required. It creates the `marc_appnet` network if needed, renders `nginx/nginx.conf`, and starts the db-sync, production, development, and nginx stacks.

### Manual bring-up

If you prefer to run stacks individually, set all required environment variables and render the nginx config yourself:

```bash
export OPENAI_API_KEY=sk-...
export MARC_PROD_IMAGE=ctbushman/marc_web:1.0.0
export MARC_PROD_POOL=prod-20240925
export MARC_DEV_IMAGE=ctbushman/marc_web:1.0.0-dev
export MARC_DEV_POOL=dev-20240925
export MARC_NFS_DB_PATH=/mnt/isilon/marc_genomics/marc_web_db_RO/marc.sqlite

podman network create marc_appnet

podman-compose -f db-sync/docker-compose.yaml up -d
podman-compose -f prod/docker-compose.yaml -p "marc-${MARC_PROD_POOL}" up -d
podman-compose -f dev/docker-compose.yaml -p "marc-${MARC_DEV_POOL}" up -d
MARC_PROD_POOL="$MARC_PROD_POOL" MARC_DEV_POOL="$MARC_DEV_POOL" envsubst '$MARC_PROD_POOL $MARC_DEV_POOL' < nginx/nginx.conf.template > nginx/nginx.conf
podman-compose -f nginx/docker-compose.yaml up -d
```

Then visit:

- http://localhost:8080/ → simple nginx landing page confirming the proxy is reachable with links to each pool
- http://localhost:8080/prod/ → load-balanced across the configured production pool
- http://localhost:8080/dev/ → served by the configured development pool
- http://localhost:8080/health → nginx health endpoint returning JSON for quick checks

To tear down, run `podman-compose -f <stack>/docker-compose.yaml down` for each stack you started.

## Finding, stopping, and removing everything

- List all marc-related containers and their status:

  ```bash
  podman ps --format '{{.Names}}\t{{.Status}}' | grep marc-
  ```

- Stop every stack using the same explicit values you used to start them:

  ```bash
  export OPENAI_API_KEY=sk-...
  export MARC_PROD_IMAGE=ctbushman/marc_web:1.0.0
  export MARC_PROD_POOL=prod-20240925
  export MARC_DEV_IMAGE=ctbushman/marc_web:1.0.0-dev
  export MARC_DEV_POOL=dev-20240925
  export MARC_NFS_DB_PATH=/mnt/isilon/marc_genomics/marc_web_db_RO/marc.sqlite

  podman-compose -f nginx/docker-compose.yaml down
  podman-compose -f prod/docker-compose.yaml -p "marc-${MARC_PROD_POOL}" down
  podman-compose -f dev/docker-compose.yaml -p "marc-${MARC_DEV_POOL}" down
  podman-compose -f db-sync/docker-compose.yaml down
  ```

- Remove generated config and shared resources if you want a clean slate:

  ```bash
  rm -f nginx/nginx.conf
  podman network rm marc_appnet
  ```

## Zero-downtime production upgrades

Use the helper script to perform a blue/green-style upgrade without dropping traffic. The script:

1. Starts a new production pool (with unique container names based on `MARC_PROD_POOL`) using the provided image tag.
2. Waits for both new containers to become healthy.
3. Ensures the `marc_appnet` network exists and that the new containers are attached to it alongside nginx.
4. Regenerates `nginx/nginx.conf` from `nginx/nginx.conf.template` to point production traffic at the new pool, reloads nginx, and verifies the proxy can reach each new backend.
5. Shuts down the previous production pool only after the new pool is reachable from nginx; otherwise it rolls back to the prior pool.

Example (all flags required, no defaults):

```bash
export OPENAI_API_KEY=sk-...
./scripts/upgrade_prod_pool.sh --image ctbushman/marc_web:0.3.8 --pool prod-blue --dev-pool dev-20240925 --timeout 300 --compose-bin podman-compose
```

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
