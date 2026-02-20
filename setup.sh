#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="traefik-gateway-demo"
GATEWAY_API_VERSION="v1.4.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_ENTRIES="127.0.0.1 whoami.localhost demo.localhost traefik.localhost"

# ----------------------------------------------------------------------------
# Colour helpers
# ----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# 1. Prerequisites
# ----------------------------------------------------------------------------
check_prerequisites() {
  info "Checking prerequisites..."
  local missing=()
  for cmd in kind kubectl helm; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}\nInstall them and re-run this script."
  fi
  success "kind, kubectl, and helm are available"
}

# ----------------------------------------------------------------------------
# 1b. inotify limits (kube-proxy crashes with "too many open files" if low)
# ----------------------------------------------------------------------------
ensure_inotify_limits() {
  local watches instances
  watches=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
  instances=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)
  if [[ "${watches}" -lt 524288 ]] || [[ "${instances}" -lt 512 ]]; then
    warn "inotify limits are low (watches=${watches}, instances=${instances})"
    warn "kube-proxy may crash — raising limits now (requires sudo)..."
    sudo sysctl -q fs.inotify.max_user_watches=524288
    sudo sysctl -q fs.inotify.max_user_instances=512
    success "inotify limits raised"
  else
    success "inotify limits OK (watches=${watches}, instances=${instances})"
  fi
}

# ----------------------------------------------------------------------------
# 2. kind cluster
# ----------------------------------------------------------------------------
create_cluster() {
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    warn "Kind cluster '${CLUSTER_NAME}' already exists — skipping creation"
  else
    info "Creating kind cluster '${CLUSTER_NAME}'..."
    kind create cluster \
      --name "${CLUSTER_NAME}" \
      --config "${SCRIPT_DIR}/kind/cluster.yaml"
    success "Kind cluster created"
  fi
}

# ----------------------------------------------------------------------------
# 3. Gateway API CRDs
# ----------------------------------------------------------------------------
install_gateway_crds() {
  info "Installing Gateway API CRDs (${GATEWAY_API_VERSION}) ..."
  kubectl apply --server-side \
    -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
  success "Gateway API CRDs installed"
}

# ----------------------------------------------------------------------------
# 4. Traefik (via Helm)
# ----------------------------------------------------------------------------
install_traefik() {
  info "Adding Traefik Helm repository..."
  helm repo add traefik https://traefik.github.io/charts --force-update >/dev/null
  helm repo update traefik >/dev/null

  info "Installing Traefik (this may take a minute)..."
  kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  helm upgrade --install traefik traefik/traefik \
    --namespace traefik \
    --values "${SCRIPT_DIR}/manifests/traefik-values.yaml" \
    --wait \
    --timeout 120s

  success "Traefik installed and ready"
}

# ----------------------------------------------------------------------------
# 5. Demo applications + HTTPRoutes
# ----------------------------------------------------------------------------
deploy_apps() {
  info "Deploying demo applications..."
  kubectl apply -f "${SCRIPT_DIR}/manifests/demo-namespace.yaml"
  kubectl apply -f "${SCRIPT_DIR}/manifests/whoami-v1.yaml"
  kubectl apply -f "${SCRIPT_DIR}/manifests/whoami-v2.yaml"
  success "whoami-v1 and whoami-v2 deployed"

  info "Applying Gateway and HTTPRoutes..."
  kubectl apply -f "${SCRIPT_DIR}/manifests/gateway.yaml"
  kubectl apply -f "${SCRIPT_DIR}/manifests/httproute-host.yaml"
  kubectl apply -f "${SCRIPT_DIR}/manifests/httproute-path.yaml"
  kubectl apply -f "${SCRIPT_DIR}/manifests/httproute-dashboard.yaml"
  success "Gateway and HTTPRoutes applied"

  info "Waiting for whoami pods to be ready..."
  kubectl rollout status deployment/whoami-v1 -n demo --timeout=60s
  kubectl rollout status deployment/whoami-v2 -n demo --timeout=60s
  success "All pods ready"
}

# ----------------------------------------------------------------------------
# 6. /etc/hosts
# ----------------------------------------------------------------------------
setup_hosts() {
  echo ""
  if grep -q "whoami.localhost" /etc/hosts 2>/dev/null; then
    success "/etc/hosts entries already present"
    return
  fi

  echo -e "${BOLD}Hostname routing requires these entries in /etc/hosts:${NC}"
  echo "  ${HOSTS_ENTRIES}"
  echo ""
  read -r -p "  Add them now? (requires sudo) [y/N]: " response </dev/tty || response="n"
  if [[ "${response}" =~ ^[Yy]$ ]]; then
    echo "${HOSTS_ENTRIES}" | sudo tee -a /etc/hosts >/dev/null
    success "/etc/hosts updated"
  else
    warn "Skipped — add the following line to /etc/hosts manually:"
    echo "  ${HOSTS_ENTRIES}"
  fi
}

# ----------------------------------------------------------------------------
# 7. Summary
# ----------------------------------------------------------------------------
print_summary() {
  echo ""
  echo -e "${GREEN}${BOLD}========================================${NC}"
  echo -e "${GREEN}${BOLD}  Demo cluster is ready!${NC}"
  echo -e "${GREEN}${BOLD}========================================${NC}"
  echo ""
  echo -e "${BOLD}Gateway API resources:${NC}"
  kubectl get gatewayclass,gateway,httproute -A 2>/dev/null || true
  echo ""
  echo -e "${BOLD}Test hostname-based routing:${NC}"
  echo "  curl http://whoami.localhost"
  echo ""
  echo -e "${BOLD}Test path-based routing:${NC}"
  echo "  curl http://demo.localhost/v1    # -> whoami-v1"
  echo "  curl http://demo.localhost/v2    # -> whoami-v2"
  echo ""
  echo -e "${BOLD}Traefik dashboard (routed via HTTPRoute):${NC}"
  echo "  http://traefik.localhost/dashboard/"
  echo ""
  echo -e "${BOLD}Tear down:${NC}"
  echo "  ./teardown.sh"
  echo ""
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  echo ""
  echo -e "${BLUE}${BOLD}Traefik + Kubernetes Gateway API Demo${NC}"
  echo -e "${BLUE}${BOLD}======================================${NC}"
  echo ""

  check_prerequisites
  ensure_inotify_limits
  create_cluster
  install_gateway_crds
  install_traefik
  deploy_apps
  setup_hosts
  print_summary
}

main "$@"
