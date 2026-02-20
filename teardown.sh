#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="traefik-gateway-demo"

echo "Deleting kind cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}"
echo "Done."

echo ""
echo "Note: if you added entries to /etc/hosts, remove this line manually:"
echo "  127.0.0.1 whoami.localhost demo.localhost traefik.localhost"
