# marc_infra

Podman Compose stacks for running the `marc_web` application with separate production, development, database sync, and nginx layers that all attach to a shared Podman network.

## Start on a fresh system

```bash
sudo mkdir -p /var/log/marc
sudo chown $USER /var/log/marc

sudo podman network create marc_appnet

cat example.env > .env
### EDIT .env WITH APPROPRIATE VALUES ###

sudo podman-compose -f prod/docker-compose.yaml up -d
sudo podman-compose -f dev/docker-compose.yaml up -d

envsubst '$MARC_PROD_POOL $MARC_DEV_POOL' < nginx/nginx.conf.template > nginx/nginx.conf
sudo podman-compose -f nginx/docker-compose.yaml up -d
```

Then visit (replacing localhost with the actual server address e.g. reslnmarc02.research.chop.edu):

- http://localhost:8080/ → simple nginx landing page confirming the proxy is reachable with links to each pool
- http://localhost:8080/prod/ → load-balanced across the configured production pool
- http://localhost:8080/dev/ → served by the configured development pool
- http://localhost:8080/health → nginx health endpoint returning JSON for quick checks

## Tear down

To tear down, run `podman-compose -f <stack>/docker-compose.yaml down` for each stack you started.

Remove generated config and shared resources if you want a clean slate:

```bash
rm -f nginx/nginx.conf
podman network rm marc_appnet
```

Check everything is gone with:

```
sudo podman ps -a
sudo podman pod ps
sudo podman network ls
```

## Dev upgrades

Upgrading/downgrading dev is easy because we don't care if it goes down for a bit. Just `sudo podman-compose -f dev/docker-compose.yaml down` and once that is successful, update `MARC_DEV_IMAGE` in `.env` and run `sudo podman-compose -f dev/docker-compose.yaml up -d`.

## Zero-downtime production upgrades

Upgrading/downgrading production is harder because we always want to have a live site to point to. So we employ the blue/green upgrade tactic, creating a new pool of containers with the new version of the site, waiting until they are live, and then switching nginx to point to them. Only once the traffic is successfully routing to the new pool do we remove the old one.

Use the helper script to perform a blue/green-style upgrade without dropping traffic. The script:

1. Starts a new production pool (with unique container names based on `MARC_PROD_POOL`) using the provided image tag.
2. Waits for new containers to become healthy.
3. Ensures the `marc_appnet` network exists and that the new containers are attached to it alongside nginx.
4. Regenerates `nginx/nginx.conf` from `nginx/nginx.conf.template` to point production traffic at the new pool, reloads nginx, and verifies the proxy can reach each new backend.
5. Shuts down the previous production pool only after the new pool is reachable from nginx; otherwise it rolls back to the prior pool.

Example (all flags required, no defaults):

```bash
export OPENAI_API_KEY=sk-...
./scripts/upgrade_prod_pool.sh --image ctbushman/marc_web:0.3.8 --pool prod-blue --dev-pool dev-20240925 --timeout 300 --compose-bin podman-compose
```

## Logging

Check `sudo podman logs <container-name>` or `/var/log/marc/`.
