# Nginx debugging guide

When requests are unexpectedly redirecting or failing through the load balancer, use these steps to pinpoint what nginx sees and where traffic is headed.

## Inspect the live config

The container renders templates on start. Dump the active config to ensure the expected settings made it in:

```bash
sudo podman-compose exec nginx nginx -T
```

## Tail rich access and error logs

Access logs now capture upstream host, status, and response times. Tail both logs to correlate the client request with the backend chosen:

```bash
sudo podman-compose exec nginx tail -f /var/log/nginx/access.log /var/log/nginx/error.log
```

Key fields:
- `host` – Host header received by nginx
- `upstream` – backend host/port selected
- `upstream_status` – HTTP status returned by the backend
- `request_time` / `upstream_response_time` – timing breakdowns

## Curl with headers to see upstream selection

Hit the proxy and inspect the response headers that expose upstream details:

```bash
curl -i http://0.0.0.0:8080/
```

Look for `X-Upstream-Addr` and `X-Upstream-Status` to confirm which backend was used and what it returned.

## Check basic nginx health

Use the built-in status page to make sure workers and upstreams are alive (only accessible inside the container by default):

```bash
sudo podman-compose exec nginx curl -s http://127.0.0.1/nginx_status
```

It should return active connections and request counters.

## Verify upstream name resolution

Ensure the nginx container can resolve the service hostnames defined in `docker-compose.yaml`:

```bash
sudo podman-compose exec nginx getent hosts marc-web-prod-a marc-web-prod-b marc-web-dev-a marc-web-dev-b
```

If resolution fails, the proxy cannot reach the backends.

## Reload after edits

After tweaking the config locally, rebuild/recreate to pick up changes:

```bash
sudo podman-compose down
sudo podman-compose up -d --build
```
