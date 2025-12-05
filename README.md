# marc_infra

Podman Compose stack for running the `marc_web` application with both production and development deployments behind a single NGINX load balancer.

## Layout

```
marc_infra/
├── dev/                  # optional context for dev image build
├── prod/                 # optional context for prod image build
├── nginx/
│   └── nginx.conf        # reverse proxy + load balancer configuration
└── docker-compose.yaml   # podman-compose entrypoint
```

## Services

- **marc-web-prod-a / marc-web-prod-b**: two production instances of `marc_web` sharing the `appnet` bridge network.
- **marc-web-dev-a / marc-web-dev-b**: two development instances of `marc_web` on the same network.
- **nginx**: reverse proxy and path-based load balancer, exposing port `8080` on the host. Traffic to `/prod/` is sent to the production pool; `/dev/` is sent to the development pool.

Images default to the public `ghcr.io/pennchopmicrobiomeprogram/marc_web` registry with `prod` and `dev` tags. Swap images or add build contexts in `prod/` and `dev/` if you need to build locally.

## Usage

Start the stack with Podman Compose:

```bash
podman-compose up -d
```

Then visit:

- http://localhost:8080/prod/ → load-balanced across `marc-web-prod-a` and `marc-web-prod-b`
- http://localhost:8080/dev/ → load-balanced across `marc-web-dev-a` and `marc-web-dev-b`

To tear down:

```bash
podman-compose down
```
