#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NETWORK_NAME="appnet"
PODS=("marc-web-prod-a" "marc-web-prod-b")
YAMLS=("${ROOT_DIR}/prod/marc-web-prod-a.yaml" "${ROOT_DIR}/prod/marc-web-prod-b.yaml")

ensure_network() {
  if ! podman network exists "${NETWORK_NAME}"; then
    podman network create "${NETWORK_NAME}"
  fi
}

wait_for_pod() {
  local pod_name="$1"
  echo "Waiting for pod ${pod_name} to become ready..."
  local container_id
  until container_id=$(podman ps --filter "label=io.podman.kube.pod.name=${pod_name}" --format "{{.ID}}" | head -n 1) && [ -n "${container_id}" ]; do
    sleep 2
  done
  local attempts=0
  until podman exec "${container_id}" python -c "import urllib.request,sys;sys.exit(0 if urllib.request.urlopen('http://localhost/health').getcode()<400 else 1)" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if (( attempts > 30 )); then
      echo "${pod_name} did not become healthy in time" >&2
      exit 1
    fi
    sleep 4
  done
  echo "${pod_name} is healthy"
}

main() {
  ensure_network
  for index in ${!PODS[@]}; do
    pod_name=${PODS[$index]}
    yaml_path=${YAMLS[$index]}
    echo "Deploying ${pod_name} from ${yaml_path}"
    podman kube play --replace --network "${NETWORK_NAME}" "${yaml_path}"
    wait_for_pod "${pod_name}"
  done
}

main "$@"
