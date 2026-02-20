# Traefik + Kubernetes Gateway API Demo

A self-contained demo that runs a [kind](https://kind.sigs.k8s.io/) cluster with
[Traefik](https://traefik.io/traefik/) acting as the Gateway API implementation.
It demonstrates both hostname-based and path-based HTTP routing using standard
Gateway API resources (`GatewayClass`, `Gateway`, `HTTPRoute`).

## Architecture

```
localhost:80
    │
    │  kind extraPortMappings (host → kind node)
    ▼
kind node :80
    │
    │  Kubernetes hostPort (kind node → Traefik DaemonSet pod)
    ▼
Traefik DaemonSet pod (namespace: traefik)
    │
    │  kubernetesGateway provider watches Gateway API objects
    ▼
Gateway "traefik-gateway"  (GatewayClass: traefik)
    │
    ├── HTTPRoute: whoami.localhost      ──► whoami-v1  (namespace: demo)
    ├── HTTPRoute: demo.localhost/v1     ──► whoami-v1  (namespace: demo)
    ├── HTTPRoute: demo.localhost/v2     ──► whoami-v2  (namespace: demo)
    └── HTTPRoute: traefik.localhost     ──► Traefik dashboard :9000
```

### Gateway API resource hierarchy

| Resource | Name | Namespace | Purpose |
|---|---|---|---|
| `GatewayClass` | `traefik` | cluster-scoped | Identifies Traefik as the controller |
| `Gateway` | `traefik-gateway` | `traefik` | Single HTTP listener on port 8000 |
| `HTTPRoute` | `whoami-host` | `demo` | Hostname-based routing |
| `HTTPRoute` | `whoami-path` | `demo` | Path-based routing |
| `HTTPRoute` | `traefik-dashboard` | `traefik` | Dashboard via Gateway API |

## Traffic flow walkthrough

There are two distinct planes to understand: the **control plane**, where Gateway
API objects are translated into Traefik routing rules, and the **data plane**,
where individual HTTP requests travel from your terminal to a backend pod.

### Control plane — how routing rules are built

When the cluster starts, Traefik's `kubernetesGateway` provider watches the
Kubernetes API for Gateway API objects and builds its internal routing table:

```
 ┌─────────────────────────────────────────────────────────────────────┐
 │  Kubernetes API Server                                              │
 │                                                                     │
 │  GatewayClass "traefik"  ──► Traefik sees its own controller name  │
 │         │                    and marks the class Accepted           │
 │         ▼                                                           │
 │  Gateway "traefik-gateway"  ──► Traefik opens a listener on its    │
 │  namespace: traefik             internal port 8000 (the "web"       │
 │  listener port: 8000            entrypoint) and marks it Programmed │
 │  allowedRoutes: All             │                                   │
 │         │                       │                                   │
 │         ▼                       │                                   │
 │  HTTPRoute "whoami-host"        │  Traefik reads the parentRef,     │
 │  namespace: demo           ◄────┘  resolves the backend Service to  │
 │  hostname: whoami.localhost        Endpoint IP addresses, and adds  │
 │  backend: whoami-v1:80             the rule to its router:          │
 │                                    Host(`whoami.localhost`) → pods  │
 └─────────────────────────────────────────────────────────────────────┘
```

Traefik does **not** use kube-proxy or ClusterIP VIPs to reach backends. It
watches `Endpoints` (or `EndpointSlices`) directly and load-balances across
individual pod IPs using its own connection pool.

The same process applies to `whoami-path` (two rules in one HTTPRoute) and
`traefik-dashboard`. Every time a pod is added, removed, or an HTTPRoute is
changed, Traefik reconciles its routing table automatically.

### Data plane — how a single request travels

Tracing `curl http://whoami.localhost/` step by step:

```
Step 1 — DNS resolution
  curl resolves "whoami.localhost" via /etc/hosts → 127.0.0.1
  (no DNS server involved; the entry was added by setup.sh)

Step 2 — TCP connection leaves the host
  curl opens a TCP connection to 127.0.0.1:80

Step 3 — Docker port mapping (extraPortMappings)
  The kind node is a Docker container. Docker has an iptables DNAT rule
  that rewrites the destination:
    127.0.0.1:80  ──►  <kind-node-container-IP>:80
  This rule was created by the extraPortMappings in kind/cluster.yaml.

Step 4 — Kubernetes hostPort (inside the kind node)
  Inside the kind node, kubelet/CNI has an iptables DNAT rule that rewrites
  the destination again:
    <kind-node-IP>:80  ──►  <traefik-pod-IP>:8000
  This rule exists because the Traefik DaemonSet pod declares hostPort: 80
  mapping to containerPort: 8000 (Traefik's "web" entrypoint).

Step 5 — Traefik receives the HTTP request
  Traefik reads the HTTP/1.1 request line and headers:
    GET / HTTP/1.1
    Host: whoami.localhost          ← used for hostname matching
  It looks up "whoami.localhost" in its routing table and finds the rule
  built from the "whoami-host" HTTPRoute.

Step 6 — Traefik selects a backend pod
  The HTTPRoute points to Service whoami-v1. Traefik has already resolved
  this to the two pod IPs (e.g. 10.244.0.5 and 10.244.0.9) by watching
  Endpoints directly. It round-robins between them.
  Traefik opens a new TCP connection directly to the chosen pod IP:80,
  bypassing kube-proxy entirely.

Step 7 — Traefik forwards the request
  Traefik proxies the request to the pod, adding headers:
    X-Forwarded-For: <original client IP>
    X-Forwarded-Host: whoami.localhost
    X-Forwarded-Proto: http
    X-Real-Ip: <original client IP>

Step 8 — Response returns
  The pod sends its response back to Traefik, which forwards it to curl.
  The TCP connections are torn down (or kept alive for reuse).
```

The same path applies to path-based routing (`demo.localhost/v1`), except
Traefik additionally matches on the URL path prefix at Step 5 to pick the
correct backend.

For the dashboard route (`traefik.localhost`), Traefik routes the request to
its own Service on port 9000 — it proxies the request to itself.

### Port numbers at each layer

It's easy to get confused by the port numbers because they change at each
boundary:

| Layer | Port | Why |
|---|---|---|
| `/etc/hosts` + curl | `80` | The standard HTTP port the user types |
| Docker extraPortMappings | `80 → 80` | kind maps host:80 to node-container:80 |
| Kubernetes hostPort | `80 → 8000` | Traefik's "web" entrypoint is on 8000 internally |
| Gateway listener | `8000` | Must match Traefik's entrypoint, not the host-facing port |
| HTTPRoute parentRef | (no port) | Attaches to the named listener "web" on the Gateway |
| Backend Service | `80` | The ClusterIP Service port for whoami pods |
| Pod containerPort | `80` | The port the whoami process listens on |

## Prerequisites

| Tool | Purpose |
|---|---|
| [`kind`](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) | Local Kubernetes cluster in Docker |
| [`kubectl`](https://kubernetes.io/docs/tasks/tools/) | Kubernetes CLI |
| [`helm`](https://helm.sh/docs/intro/install/) | Traefik installation |

## Quick start

```bash
./setup.sh
```

The script will:

1. Create a kind cluster with ports 80 and 443 mapped to localhost
2. Install the Gateway API CRDs (v1.4.0, standard channel)
3. Install Traefik via Helm with the `kubernetesGateway` provider enabled
4. Deploy `whoami-v1` and `whoami-v2` sample applications
5. Apply three `HTTPRoute` resources
6. Optionally add the required `/etc/hosts` entries

## Testing

### /etc/hosts

The demo uses `*.localhost` hostnames. Add this line to `/etc/hosts` if the
setup script didn't do it automatically:

```
127.0.0.1 whoami.localhost demo.localhost traefik.localhost
```

### Hostname-based routing

```bash
curl http://whoami.localhost
```

All traffic to `whoami.localhost` is routed to `whoami-v1`.  The response shows
the pod hostname, confirming which backend served the request.

### Path-based routing

```bash
# Routes to whoami-v1
curl http://demo.localhost/v1

# Routes to whoami-v2
curl http://demo.localhost/v2
```

Both paths share the same hostname (`demo.localhost`). Traefik selects the
backend based on the path prefix defined in the `HTTPRoute`.

### Traefik dashboard

Open in a browser:

```
http://traefik.localhost/dashboard/
```

Traffic reaches the dashboard by routing through the Gateway itself — the
`traefik-dashboard` HTTPRoute forwards requests to the `traefik` Service on
port 9000.

### Inspect Gateway API objects

```bash
# Overview of all Gateway API resources
kubectl get gatewayclass,gateway,httproute -A

# Check route attachment status (Accepted / ResolvedRefs conditions)
kubectl describe httproute whoami-host -n demo
kubectl describe httproute whoami-path -n demo
kubectl describe httproute traefik-dashboard -n traefik

# Watch Traefik logs
kubectl logs -n traefik -l app.kubernetes.io/name=traefik -f
```

## Key design decisions

**DaemonSet + hostPort** — Traefik runs as a DaemonSet so it can bind directly
to host port 80 via Kubernetes `hostPort`. This avoids needing a LoadBalancer or
MetalLB in a local kind environment.

**kind extraPortMappings** — The kind node maps host port 80 → container port 80,
completing the path from `localhost:80` to the Traefik pod.

**Gateway API only** — `providers.kubernetesIngress` is disabled so the cluster
uses exclusively Gateway API objects. No `Ingress` resources are used.

**Cross-namespace HTTPRoutes** — Routes in the `demo` namespace attach to the
Gateway in the `traefik` namespace. This is permitted because the Gateway is
configured with `allowedRoutes.namespaces.from: All` (via `namespacePolicy: All`
in the Helm values). No `ReferenceGrant` is needed for this direction.

**No ReferenceGrant for backends** — Each HTTPRoute lives in the same namespace
as its backend Services, so no `ReferenceGrant` is required for those references.

**Explicit Gateway manifest** — We provide our own `manifests/gateway.yaml`
rather than using the Helm chart's auto-created Gateway. The Helm chart (v39)
creates the Gateway with `allowedRoutes.namespaces.from: Same`, which blocks
cross-namespace HTTPRoute attachment from the `demo` namespace. Our manifest
sets `from: All` explicitly, and sets the listener port to `8000` to match
Traefik's internal `web` entrypoint port.

**inotify limits on Linux** — Running kind may require raising the system
inotify limits or kube-proxy will crash-loop with "too many open files".
If you see kube-proxy in `CrashLoopBackOff`, run:
```bash
sudo sysctl fs.inotify.max_user_watches=524288
sudo sysctl fs.inotify.max_user_instances=512
```
To make this permanent add those lines to `/etc/sysctl.conf`.

## File structure

```
.
├── setup.sh                        # Bootstrap script
├── teardown.sh                     # Cleanup script
├── kind/
│   └── cluster.yaml                # kind cluster config (extraPortMappings)
└── manifests/
    ├── traefik-values.yaml         # Traefik Helm values
    ├── demo-namespace.yaml         # "demo" namespace
    ├── whoami-v1.yaml              # Deployment + Service (v1)
    ├── whoami-v2.yaml              # Deployment + Service (v2)
    ├── httproute-host.yaml         # whoami.localhost → whoami-v1
    ├── httproute-path.yaml         # demo.localhost/v1 and /v2
    └── httproute-dashboard.yaml    # traefik.localhost → dashboard
```

## Tear down

```bash
./teardown.sh
```

This deletes the kind cluster. All Kubernetes resources are destroyed with it.
Remove the `/etc/hosts` entries manually if needed.

## References

- [Traefik Kubernetes Gateway API reference](https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-gateway/)
- [Traefik routing configuration — Gateway API](https://doc.traefik.io/traefik/reference/routing-configuration/kubernetes/gateway-api/)
- [Gateway API concepts](https://gateway-api.sigs.k8s.io/concepts/api-overview/)
- [kind — Local clusters for Kubernetes](https://kind.sigs.k8s.io/)
