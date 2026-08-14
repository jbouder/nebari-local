# nebari-local

Local Nebari cluster deployed with [NIC](https://github.com/nebari-dev/nebari-infrastructure-core)
(Nebari Infrastructure Core) using the `local` provider (kind + MetalLB).

This repo holds both the NIC config (`nebari-config.yaml`) and the GitOps tree
(`gitops/`) that ArgoCD syncs from. The repo is mounted into the kind node so
the in-cluster ArgoCD repo-server can read it via `file://`.

## Deploy

Requires NIC **>= 0.12.0** (`brew install nebari-dev/tap/nic`).

```bash
nic deploy -f nebari-config.yaml
```

This creates a kind cluster named `nebari-local` (kubectl context
`kind-nebari-local`), installs MetalLB, bootstraps ArgoCD, and commits the
foundational app-of-apps manifests (cert-manager, Envoy Gateway, Keycloak,
PostgreSQL, nebari-operator, nebari-landingpage, OpenTelemetry collector)
into `gitops/`.

## Software packs

Beyond the foundational apps, `gitops/apps/` adds these packs (synced by
ArgoCD from this repo — add/edit a manifest, commit, and ArgoCD picks it up).
Pack Applications must declare `project: nebari-apps` — since NIC 0.12 the
`default` AppProject is deny-all and `foundational` is reserved for
NIC-owned apps; `nebari-apps` allows any source repo and any namespace:

| Pack | URL | Notes |
|---|---|---|
| Data Science (JupyterHub) | https://hub.nebari.local | Small/Medium spawn profiles |
| Nebi | https://nebi.nebari.local | pixi environment management |
| Nebari Chat | https://chat.nebari.local | nebari-dev/chat-pack (frontend + ravnar backend) |
| Provenance Collector | https://provenance.nebari.local | Daily scan at 06:00; http persistence mode |
| Apps | https://apps.nebari.local | Launch static/pixi web apps (UI + API + MCP at /mcp); apps serve at `<name>.apps.nebari.local` |
| Harbor | https://harbor.nebari.local | OCI registry + Trivy scanning; "LOGIN VIA OIDC PROVIDER" (Keycloak) or `admin` with the harbor-admin secret |

Local-cluster conventions used in these manifests: backend OIDC calls go to
the in-cluster Keycloak service
(`http://keycloak-keycloakx-http.keycloak.svc.cluster.local:8080`) because the
external `keycloak.nebari.local` hostname is neither resolvable nor trusted
from inside pods; storage classes use the kind default (`standard`).

**Apple Silicon note:** nebi and provenance-collector publish amd64-only
images. On an arm64 kind node these fail with "no match for platform in
manifest". Two workarounds are in use (Docker Desktop's Rosetta runs the
amd64 binaries either way):

1. *Digest pin* (nebi): set the image tag to `tag@sha256:<amd64-digest>` —
   containerd pulls the referenced manifest without platform matching. Get
   the digest with:
   ```bash
   TOKEN=$(curl -s "https://quay.io/v2/auth?service=quay.io&scope=repository:<org>/<repo>:pull" | jq -r .token)
   curl -s -H "Authorization: Bearer $TOKEN" \
     -H "Accept: application/vnd.oci.image.index.v1+json" \
     "https://quay.io/v2/<org>/<repo>/manifests/<tag>" | \
     jq -r '.manifests[] | select(.platform.architecture=="amd64") | .digest'
   ```
2. *Node-side digest pull + retag* (provenance-collector — its chart reuses
   `image.tag` in a k8s label, where a digest is invalid, so the manifest
   can't be digest-pinned). Pull the amd64 manifest by digest directly on
   the kind node and force-tag it; kubelet then finds a platform-usable
   image via `IfNotPresent`. Importing via `docker save | ctr images import`
   does NOT work — the stored index still fails containerd's platform match.
   ```bash
   docker exec nebari-local-control-plane ctr -n k8s.io images pull \
     --platform linux/amd64 <image>@sha256:<amd64-manifest-digest>
   docker exec nebari-local-control-plane ctr -n k8s.io images tag --force \
     <image>@sha256:<amd64-manifest-digest> <image>:<tag>
   ```
   Required after a cluster recreate for:
   - `quay.io/nebari/provenance-collector:0.1.2`
     (`sha256:c18bcf8a8c70bc60425b9293d0bbea3da857ae39f2a16d2b8aaee2ca447c7668`)
   - `ghcr.io/nebari-dev/provenance-collector-pack/frontend:0.1.2`
     (`sha256:08c87115afef393f498220b8fe43c338a511798d6183527cfce9acbf3d92f9b9`)

**Chat:** the deployed chat is `nebari-dev/chat-pack` (public images,
multi-arch). The OpenTeams Chat++ pack was considered first but its chart
and image on `quay.io/openteams` are private and would need a quay pull
token wired into an ArgoCD repository secret plus an imagePullSecret.

### In-cluster access to `*.nebari.local` (required for pack OIDC)

Keycloak pins its token issuer to `https://keycloak.nebari.local`, and pack
backends (nebi JWKS fetch, chat token validation) must reach that URL from
inside the cluster. Without help it resolves to 127.0.0.1 in-cluster
(Docker Desktop's DNS reads the Mac's `/etc/hosts`), causing Keycloak
redirect loops. Two out-of-band pieces fix this — **both must be re-applied
after a cluster recreate**:

1. **CoreDNS rewrite** — send `*.nebari.local` to the Envoy gateway. Add to
   the `kube-system/coredns` ConfigMap's Corefile (before the `kubernetes`
   block), then `kubectl rollout restart deploy/coredns -n kube-system`:
   ```
   rewrite stop {
      name regex (.*\.)?nebari\.local envoy-envoy-gateway-system-nebari-gateway-be66687c.envoy-gateway-system.svc.cluster.local
      answer auto
   }
   ```
   (The service name is the gateway's generated Envoy service — check with
   `kubectl get svc -n envoy-gateway-system`.)

2. **CA-bundle ConfigMaps** — backends must trust the gateway's self-signed
   cert. Build a bundle (system roots + live gateway cert, so real outbound
   TLS keeps working) and create it in each consuming namespace:
   ```bash
   echo | openssl s_client -connect 127.0.0.1:443 -servername keycloak.nebari.local 2>/dev/null | \
     openssl x509 -outform PEM > /tmp/gateway.crt
   cat /etc/ssl/cert.pem /tmp/gateway.crt > /tmp/ca-bundle.crt
   for ns in nebi nebari-chat; do
     kubectl --context kind-nebari-local delete configmap nebari-local-ca-bundle -n $ns --ignore-not-found
     kubectl --context kind-nebari-local create configmap nebari-local-ca-bundle -n $ns \
       --from-file=ca-bundle.crt=/tmp/ca-bundle.crt
   done
   ```
   Also re-run this if cert-manager rotates the gateway cert (~1 year).
   The pack manifests reference the ConfigMap via `orgCABundle` (nebi) and
   `ravnar.extraEnv/extraVolumes` (chat).

3. **Harbor admin password secret** — Harbor's own admin account and the
   OIDC-setup Job both read one out-of-band secret (never committed):
   ```bash
   kubectl --context kind-nebari-local create namespace harbor
   kubectl --context kind-nebari-local -n harbor create secret generic harbor-admin \
     --from-literal=HARBOR_ADMIN_PASSWORD="$(openssl rand -base64 24)"
   ```

4. **Chat postgres password secret** — the ravnar chart's generated password
   relies on helm `lookup()`, which ArgoCD can't use, so it would regenerate
   on every sync and break DB auth. The manifest instead reads a stable
   out-of-band secret:
   ```bash
   kubectl --context kind-nebari-local create secret generic nebari-chat-postgres-password \
     -n nebari-chat --from-literal=password="$(openssl rand -hex 16)"
   ```
   (On an existing database, also run
   `kubectl exec -n nebari-chat nebari-chat-ravnar-postgres-0 -- psql -U huginn -d ravnar -c "ALTER USER huginn PASSWORD '<pw>';"`
   with the same value.)

ArgoCD polls the `file://` repo on an interval; to pick up a new commit
immediately:

```bash
kubectl --context kind-nebari-local -n argocd annotate app nebari-root \
  argocd.argoproj.io/refresh=hard --overwrite
```

## Access

MetalLB assigns the gateway a Docker-network IP that macOS can't route to, so
access goes through a port-forward on the host.

**One port-forward serves everything.** All services — foundational and
software packs — share the single Envoy gateway, which routes by hostname
(SNI/Host header). Adding a pack never requires a new port-forward; it only
requires a new `/etc/hosts` entry so the browser resolves the pack's
hostname to localhost.

**One-time setup** — map every hostname to localhost (re-run the line with
new names appended whenever a pack is added):

```bash
sudo sh -c 'echo "127.0.0.1 nebari.local argocd.nebari.local keycloak.nebari.local hub.nebari.local nebi.nebari.local chat.nebari.local chat-api.nebari.local provenance.nebari.local apps.nebari.local harbor.nebari.local" >> /etc/hosts'
```

> `/etc/hosts` has no wildcard support, so every app launched through the
> Apps pack needs its own entry appended too
> (`127.0.0.1 <name>.apps.nebari.local`).

**Start the gateway forward** (must stay running; needs sudo to bind 443):

```bash
sudo kubectl --context kind-nebari-local port-forward -n envoy-gateway-system \
  svc/envoy-envoy-gateway-system-nebari-gateway-be66687c 443:443
```

> Forward on **443**, not an alternate port like 8443 — Keycloak issues
> redirects without a port, so anything else breaks after the first redirect.
> `kubectl port-forward` occasionally drops; restart it if pages stop loading.

Then browse (each hostname shows a self-signed-cert warning once — click
Advanced → Proceed, or type `thisisunsafe`):

| Service | URL |
|---|---|
| Landing page | https://nebari.local |
| Keycloak | https://keycloak.nebari.local |
| ArgoCD | https://argocd.nebari.local |

## Credentials

All passwords are generated at deploy time and stored in cluster secrets:

```bash
# Landing page / Nebari apps sign-in (Keycloak "nebari" realm; username: admin)
kubectl --context kind-nebari-local -n keycloak get secret nebari-realm-admin-credentials \
  -o jsonpath='{.data.password}' | base64 -d

# Keycloak master admin console (username: admin)
kubectl --context kind-nebari-local -n keycloak get secret keycloak-admin-credentials \
  -o jsonpath='{.data.admin-password}' | base64 -d

# ArgoCD (username: admin; or use "Log in via Keycloak" with the realm account)
kubectl --context kind-nebari-local -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

The landing page's Keycloak sign-in screen is the **nebari realm** — use the
realm admin credentials there, not the Keycloak master admin ones.

## Kubeconfig

The deploy registers the `kind-nebari-local` context in your default
kubeconfig. To print a standalone one:

```bash
nic kubeconfig -f nebari-config.yaml
```

## Teardown

```bash
nic destroy -f nebari-config.yaml
```

To rebuild from scratch, run destroy followed by deploy. Note kind mounts are
fixed at cluster creation — if the repo path changes, a destroy/deploy cycle
is required.
