# Podman Kube deployment files

This folder replaces the old podman-compose flow with standalone Kubernetes pod manifests that work with `podman kube play`. Each pod runs independently on the `appnet` CNI network so you can restart or upgrade them individually.

## Files
- `secret-openai.yaml`: Kubernetes Secret with the `OPENAI_API_KEY`. Replace the placeholder before running.
- `db-sync.yaml`: Cron-style sync job that mirrors the SQLite database from NFS into the local data directory.
- `marc-web-prod-a.yaml` / `marc-web-prod-b.yaml`: Two identical production app pods for zero-downtime rotations.
- `nginx.yaml`: Front door proxy that exposes port `8080` on the host.

## Shared host paths
The manifests mount files from this repository using relative paths (for example `./data`) so you can run them directly from the cloned repo without creating `/workspace` directories. If you relocate the repo, run `podman kube play` from that checkout so the relative `hostPath.path` entries resolve correctly. The database source file is expected at `/nfs/marc.sqlite`; adjust that path if your NFS mount differs.

## Usage
1. Ensure the `appnet` network exists:
   ```bash
   podman network exists appnet || podman network create appnet
   ```
2. Load secrets and supporting pods:
   ```bash
   podman kube play prod/secret-openai.yaml
   podman kube play --replace --network appnet prod/db-sync.yaml
   podman kube play --replace --network appnet prod/marc-web-prod-a.yaml
   podman kube play --replace --network appnet prod/marc-web-prod-b.yaml
   # Optional dev pod that shares the same data and secret
   podman kube play --replace --network appnet dev/marc-web-dev.yaml
   podman kube play --replace --network appnet prod/nginx.yaml
   ```
3. For production upgrades, use the rolling script to cycle the prod pods one at a time:
   ```bash
   ./scripts/prod-rolling-upgrade.sh
   ```
   The script recreates `marc-web-prod-a` and `marc-web-prod-b` sequentially, waiting for `/health` to respond before moving on to the next pod.
