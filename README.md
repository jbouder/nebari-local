# nebari-local

Local Nebari cluster deployed with [NIC](https://github.com/nebari-dev/nebari-infrastructure-core)
(Nebari Infrastructure Core) using the `local` provider (kind + MetalLB).

This repo holds both the NIC config (`nebari-config.yaml`) and the GitOps tree
(`gitops/`) that ArgoCD syncs from. The repo is mounted into the kind node so
the in-cluster ArgoCD repo-server can read it via `file://`.

## Quick start

From zero to a browsable cluster (each step is detailed in the sections below):

1. **Install NIC** (>= 0.12.0): `brew install nebari-dev/tap/nic`
2. **Deploy**: `nic deploy -f nebari-config.yaml` — creates the kind cluster,
   bootstraps ArgoCD, and syncs everything in `gitops/` (foundational apps +
   all software packs).
3. **Re-apply the out-of-band pieces** (required for pack OIDC; see
   [In-cluster access](#in-cluster-access-to-nebarilocal-required-for-pack-oidc)):
   CoreDNS rewrite, CA-bundle ConfigMaps, `harbor-admin` secret, and the chat
   postgres password secret.
4. **Add the `/etc/hosts` entries** — one line mapping every hostname to
   `127.0.0.1` (see [Access](#access) for the current full list).
5. **Start the gateway port-forward** (must stay running):
   ```bash
   sudo kubectl --context kind-nebari-local port-forward -n envoy-gateway-system \
     svc/envoy-envoy-gateway-system-nebari-gateway-be66687c 443:443
   ```
6. **Get the sign-in password** (username `admin`):
   ```bash
   kubectl --context kind-nebari-local -n keycloak get secret nebari-realm-admin-credentials \
     -o jsonpath='{.data.password}' | base64 -d
   ```
7. **Browse** https://nebari.local (accept the self-signed-cert warning once
   per hostname) — the landing page links to every installed pack.

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
| Frames | https://frames.nebari.local | Context Frames registry + remote MCP endpoint (vendored chart at `gitops/charts/nebari-frames` — local CA addition) |
| LLM Serving | https://llm-keys.nebari.local | llm-d operator + API-key manager UI. **No GPUs** here, so GPU `LLMModel` CRs won't schedule (default serving image is CUDA-only). Prereqs installed alongside: Envoy AI Gateway v0.5.0 + GIE v1.5.0 CRDs, and the foundational envoy-gateway app carries AI-extension wiring |
| ↳ CPU model | https://llm.nebari.local | `qwen3-0-6b` (`gitops/manifests/llm-models/`): Qwen3-0.6B GGUF on llama.cpp's multi-arch server image — `gpu.count: 0` + `serving.command` override (`sh -c` swallows the operator's vLLM args). All models share `llm.nebari.local`, routed by the `model` field in the request body |

**Try the CPU model** — mint an API key at https://llm-keys.nebari.local
(or read an existing one from the `qwen3-0-6b-api-keys` secret in
`nebari-llm-serving-system`), then:

```bash
curl -sk https://llm.nebari.local/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"ggml-org/Qwen3-0.6B-GGUF","messages":[{"role":"user","content":"Say hello. /no_think"}]}'
```

(Qwen3 is a thinking model; append ` /no_think` to prompts or raise
`max_tokens`, or the whole budget goes to reasoning tokens.)

> The Envoy AI Gateway injects its request-processing sidecar into the envoy
> proxy pod via a mutating webhook, so the proxy pod must be (re)created
> AFTER envoy-ai-gateway is installed — a pod that predates it 500s on every
> `llm.nebari.local` request (`.../run.sock: No such file or directory`). Fix:
> `kubectl rollout restart deploy/envoy-envoy-gateway-system-nebari-gateway-be66687c -n envoy-gateway-system`
> (breaks the running port-forward; restart that too).

> **JWT auth on `llm-internal.nebari.local` needs a live patch.** The
> llm-serving operator renders each model's internal SecurityPolicy with
> `remoteJWKS.uri` derived from the external issuer URL
> (`https://keycloak.nebari.local/...`), which Envoy's JWKS fetcher can't
> reach from inside the proxy (self-managed CA it doesn't trust) — every JWT
> then fails and clients see 401s: apollo-desktop model discovery comes back
> empty and the llm-keys UI shows no models/keys (creates still land in the
> `<model>-api-keys` secret). Point the JWKS at the in-cluster Keycloak
> service instead:
> ```bash
> kubectl --context kind-nebari-local -n nebari-llm-serving-system \
>   patch securitypolicy qwen3-0-6b-internal-auth --type=json \
>   -p '[{"op":"replace","path":"/spec/jwt/providers/0/remoteJWKS/uri","value":"http://keycloak-keycloakx-http.keycloak.svc.cluster.local:8080/realms/nebari/protocol/openid-connect/certs"}]'
> ```
> The operator doesn't watch SecurityPolicies, so the patch sticks until the
> `LLMModel` CR changes or the operator restarts — re-apply per model after
> either (and after cluster recreate). Proper fix: teach the operator a
> separate JWKS URL override (split-horizon, like the key-manager's
> `keyManager.keycloak.url`) in nebari-llm-serving-pack.

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

2. **CA-bundle ConfigMaps** — backends must trust the gateway certs. All
   gateway certs chain to the 10-year `nebari-local Root CA`
   (`gitops/manifests/security/issuers/root-ca.yaml`; the `selfsigned-issuer`
   ClusterIssuer is a CA issuer backed by it). Build a bundle (system roots +
   root CA, so real outbound TLS keeps working) and create it in each
   consuming namespace — the bundle stays valid across leaf renewals:
   ```bash
   kubectl --context kind-nebari-local -n cert-manager get secret nebari-local-root-ca \
     -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/nebari-local-root-ca.pem
   cat /etc/ssl/cert.pem /tmp/nebari-local-root-ca.pem > /tmp/ca-bundle.crt
   for ns in nebi nebari-chat frames; do
     kubectl --context kind-nebari-local -n $ns create configmap nebari-local-ca-bundle \
       --from-file=ca-bundle.crt=/tmp/ca-bundle.crt --dry-run=client -o yaml | \
       kubectl --context kind-nebari-local apply --server-side --force-conflicts -f -
   done
   ```
   (Server-side apply because the bundle is too large for the client-side
   last-applied annotation.) The pack manifests reference the ConfigMap via
   `orgCABundle` (nebi) and `ravnar.extraEnv/extraVolumes` (chat).

   **Workstation trust (apollo-desktop, browsers, curl):** trust the same
   root CA once in the macOS System keychain — needs a real terminal for the
   sudo password prompt:
   ```bash
   sudo security add-trusted-cert -d -r trustRoot \
     -k /Library/Keychains/System.keychain /tmp/nebari-local-root-ca.pem
   ```
   Re-run both steps only after a cluster recreate (the root CA is minted
   fresh). Leaf renewals need nothing.

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
sudo sh -c 'echo "127.0.0.1 nebari.local argocd.nebari.local keycloak.nebari.local hub.nebari.local nebi.nebari.local chat.nebari.local chat-api.nebari.local provenance.nebari.local apps.nebari.local harbor.nebari.local frames.nebari.local llm-keys.nebari.local llm.nebari.local llm-internal.nebari.local" >> /etc/hosts'
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
