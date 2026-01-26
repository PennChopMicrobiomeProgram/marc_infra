# marc_infra

Podman Compose stacks for running the `marc_web` application with separate production, development, and nginx layers that all attach to a shared Podman network.

## Start on a fresh system

```bash
sudo mkdir -p /var/log/marc
sudo chown $USER /var/log/marc

sudo podman network create marc_appnet

cat example.env > .env
### EDIT .env WITH APPROPRIATE VALUES ###

crontab -e
### Write: */10 * * * * ~/marc_infra/scripts/sync_db.sh >> /var/log/marc/marc-db-sync.log 2>&1 ###
# Careful with this one, if multiple users set up the same cronjob
# you can end up with competing processes that might block each other 
# or cause other issues

sudo podman-compose -f dev/docker-compose.yaml up -d
sudo podman-compose -f prod/docker-compose.yaml up -d

envsubst '$MARC_PROD_POOL $MARC_DEV_POOL $MARC_SSL_CERTIFICATE $MARC_SSL_CERTIFICATE_KEY' < nginx/nginx.conf.template > nginx/nginx.conf
sudo podman-compose -f nginx/docker-compose.yaml up -d
```

Then visit (replacing localhost with the actual server address e.g. reslnmarc02.research.chop.edu):

- https://localhost/ → simple nginx landing page confirming the proxy is reachable with links to each pool
- https://localhost/prod/ → served by the configured production pool
- https://localhost/dev/ → served by the configured development pool
- https://localhost/health → nginx health endpoint returning JSON for quick checks

## Tear down

To tear down, run `sudo podman-compose -f <stack>/docker-compose.yaml down` for each stack you started.

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

Remove excess resources with:

```
sudo podman stop <resource_id>
sudo podman rm <resource_id>
```

## Dev upgrades

Upgrading/downgrading dev is easy because we don't care if it goes down. Just `sudo podman-compose -f dev/docker-compose.yaml down` and once that is successful, update `MARC_DEV_IMAGE` in `.env` and run `sudo podman-compose -f dev/docker-compose.yaml up -d`.

## Zero-downtime production upgrades

Upgrading/downgrading production is harder because we always want to have a live site to point to. So we employ the blue/green upgrade tactic, creating a new production container with the new version of the site, waiting until it is live and healthy, and then switching nginx to point to it. Only once the traffic is successfully routing to the new container do we remove the old one.

Use the helper script to perform a blue/green-style upgrade without dropping traffic. The script:

1. Starts a new production pool (with unique container names based on `MARC_PROD_POOL`) using the provided image tag.
2. Waits for new container to become healthy.
4. Regenerates `nginx/nginx.conf` from `nginx/nginx.conf.template` to point production traffic at the new pool, reloads nginx, and verifies the proxy can reach each new backend.
5. Shuts down the previous production pool only after the new pool is reachable from nginx; otherwise it rolls back to the prior pool.

Make sure to update the .env file first, and then run:

```bash
./scripts/upgrade_prod.sh
```

### Note on 'pool' terminology

We use 'pool' and 'container' interchangeably here because our container pools consist of only one container. This is by design to avoid containers blocking each other's access to the database (even though it's read-only, we still want to mitigate this risk as much as possible.)

## Logging

Check `sudo podman logs <container-name>` or `/var/log/marc/`.
