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
3. **Run the post-recreate script** — automates every out-of-band piece
   (CoreDNS rewrite, out-of-band secrets, CA-bundle ConfigMaps, amd64 image
   retags, Keycloak live bits, envoy extproc restart, LLM route timeouts).
   Idempotent; re-run it any time (e.g. after an LLM model becomes Ready):
   ```bash
   ./scripts/post-recreate.sh
   ```
4. **Trust the new root CA** (fresh mint per recreate; the script leaves it
   at `/tmp/nebari-local-root-ca.pem` — needed by apollo-desktop, browsers,
   curl):
   ```bash
   sudo security add-trusted-cert -d -r trustRoot \
     -k /Library/Keychains/System.keychain /tmp/nebari-local-root-ca.pem
   ```
5. **Add the `/etc/hosts` entries** (survive recreates — only needed once, or
   when hostnames change; see [Access](#access) for the current full list).
6. **Start the gateway port-forward** (must stay running):
   ```bash
   sudo kubectl --context kind-nebari-local port-forward -n envoy-gateway-system \
     svc/envoy-envoy-gateway-system-nebari-gateway-be66687c 443:443
   ```
7. **Get the sign-in password** (username `admin`):
   ```bash
   kubectl --context kind-nebari-local -n keycloak get secret nebari-realm-admin-credentials \
     -o jsonpath='{.data.password}' | base64 -d
   ```
8. **Browse** https://nebari.local — the landing page links to every
   installed pack.

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
| ↳ CPU models | https://llm.nebari.local | Two CPU models (`gitops/manifests/llm-models/`) on llama.cpp's multi-arch server image — `gpu.count: 0` + `serving.command` override (`sh -c` swallows the operator's vLLM args). All models share `llm.nebari.local`, routed by the `model` field in the request body |

Current models (both thinking models — append ` /no_think` to prompts or
raise `max_tokens`, or the whole budget goes to reasoning tokens):

| LLMModel | Request `model` string | What it is |
|---|---|---|
| `qwen3-5-4b` | `unsloth/Qwen3.5-4B-GGUF` | Qwen3.5-4B Q4_K_M (~2.7GB) — the fast daily driver, ~30-40 tok/s |
| `qwen3-6-35b-a3b` | `ggml-org/Qwen3.6-35B-A3B-GGUF` | Qwen3.6-35B-A3B MoE Q4_K_M (~20GB, ~3B active params/token) — big-model quality at usable CPU speed |

**Try a model** — mint an API key at https://llm-keys.nebari.local
(or read an existing one from the `<model>-api-keys` secret in
`nebari-llm-serving-system`), then:

```bash
curl -sk https://llm.nebari.local/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"unsloth/Qwen3.5-4B-GGUF","messages":[{"role":"user","content":"Say hello. /no_think"}]}'
```

> The Envoy AI Gateway injects its request-processing sidecar into the envoy
> proxy pod via a mutating webhook, so the proxy pod must be (re)created
> AFTER envoy-ai-gateway is installed — a pod that predates it 500s on every
> `llm.nebari.local` request (`.../run.sock: No such file or directory`).
> `post-recreate.sh` detects the missing sidecar and restarts the proxy
> deployment automatically (this breaks a running port-forward; restart it).

> **JWT auth on `llm-internal.nebari.local`** depends on envoy fetching
> Keycloak's JWKS from the external URL the operator renders
> (`https://keycloak.nebari.local/...`). The proxy validates that fetch
> against its container's system CAs, so
> `gitops/manifests/networking/envoyproxy.yaml` overlays the proxy's CA
> bundle with the `nebari-local-ca-bundle` ConfigMap (which must exist in
> `envoy-gateway-system` — it's in the README re-create loop). Without it,
> every JWT 401s ("Jwks remote fetch is failed") and apollo-desktop model
> discovery comes back empty. Don't bother live-patching the
> SecurityPolicy's JWKS URI — the operator reconciles it back on every
> api-key Secret change.

> **Route timeout needs a live patch per model.** The ai-gateway controller
> translates each model's AIGatewayRoutes into HTTPRoutes with a default
> `request: 60s` timeout, and the operator doesn't override it for LLMModels
> (it sets 120s for passthrough models only). CPU inference easily exceeds
> 60s on long/thinking generations — streams die mid-token and apollo shows
> "The agent could not complete the model request". `post-recreate.sh`
> patches every existing model route to 600s — but the patch only sticks
> until the next LLMModel reconcile rebuilds the routes, and routes for a
> model only exist once it's Ready. **Re-run the script after a model
> becomes Ready, after any LLMModel spec change, or after a cluster
> stop/start (`docker stop/start nebari-local-control-plane`) — the
> operator's restart reconcile rebuilds all routes and wipes the patch.** Upstream fix: the
> operator should set generous route timeouts (or expose them on the CRD).

> **Known upstream bug (nebari-llm-serving-pack operator):** every LLMModel
> reconcile wipes the `<model>-api-key-metadata` ConfigMap
> (`createOrUpdateConfigMap` sets `Data` from a desired object built with
> nil Data — unlike the Secret path, which preserves data). Since key
> creation itself updates the api-keys Secret and triggers a reconcile,
> key metadata vanishes right after minting and the llm-keys UI lists no
> keys ("keys don't persist"). The key credentials themselves survive in
> the `<model>-api-keys` Secret and keep working.

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
   Required after a cluster recreate (automated by `post-recreate.sh`) for:
   - `quay.io/nebari/provenance-collector:0.1.2`
     (`sha256:c18bcf8a8c70bc60425b9293d0bbea3da857ae39f2a16d2b8aaee2ca447c7668`)
   - `ghcr.io/nebari-dev/provenance-collector-pack/frontend:0.1.2`
     (`sha256:08c87115afef393f498220b8fe43c338a511798d6183527cfce9acbf3d92f9b9`)

### In-cluster access to `*.nebari.local` (required for pack OIDC)

> **All of the below is automated by `./scripts/post-recreate.sh`** (plus
> the Keycloak live bits, image retags, extproc restart, and LLM route
> timeouts). The details are kept here as reference for what the script
> does and for one-off manual repair.

Keycloak pins its token issuer to `https://keycloak.nebari.local`, and pack
backends (nebi JWKS fetch, chat token validation) must reach that URL from
inside the cluster. Without help it resolves to 127.0.0.1 in-cluster
(Docker Desktop's DNS reads the Mac's `/etc/hosts`), causing Keycloak
redirect loops. These out-of-band pieces fix this — **all must be re-applied
after a cluster recreate** (i.e. re-run the script):

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
   for ns in nebi nebari-chat frames envoy-gateway-system; do
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

4. **Keycloak postgres credential secrets** — the pre-CNPG bitnami
   postgresql app and the keycloakx chart reference two secrets that the
   old dev NIC build created at deploy time but released NIC (>= 0.12) does
   not (its fresh trees use CNPG instead). Without them `postgresql-0`
   is stuck ContainerCreating and Keycloak in CreateContainerConfigError:
   ```bash
   PGPW=$(openssl rand -hex 16)
   kubectl --context kind-nebari-local -n keycloak create secret generic postgresql-credentials \
     --from-literal=postgres-password="$PGPW" --from-literal=user-password="$PGPW"
   kubectl --context kind-nebari-local -n keycloak create secret generic keycloak-postgresql-credentials \
     --from-literal=password="$(openssl rand -hex 16)"
   ```
   (Create BEFORE postgres first boots if possible — initdb creates the
   `keycloak` DB user from `keycloak-postgresql-credentials`. On an existing
   PVC the initdb script won't re-run; keep the old passwords or ALTER USER.)

5. **Chat postgres password secret** — the ravnar chart's generated password
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

6. **Keycloak live bits** the operator doesn't create (upstream gaps):
   - `frames-audience` client scope — an `oidc-audience-mapper` adding the
     frames SPA client id to token `aud` (frames rejects tokens without it),
     attached as a default scope to the frames SPA/device clients,
     `apollo-desktop`, and `debug-cli`.
   - `debug-cli` public client (direct-access grants, no standard flow) for
     CLI token minting:
     ```bash
     curl -s https://keycloak.nebari.local/realms/nebari/protocol/openid-connect/token \
       -d grant_type=password -d client_id=debug-cli -d username=admin \
       -d password=<realm-admin-pass> -d scope=openid
     ```
   The script waits for the operator-created frames clients before
   attaching the scope; if it warns a client wasn't found, re-run it.

7. **Chat-app LLM API keys** — the chat app's static agents
   (`gitops/apps/nebari-chat.yaml` `config.inline`) call the external LLM
   gateway with per-model `sk-` keys. The gateway authorizes exactly the
   data-key names of each model's `<model>-api-keys` Secret in
   `nebari-llm-serving-system`, so the script mints a key by writing
   `svc-nebari-chat-<model>-1: sk-<random>` straight into that Secret (no
   key-manager call; the clientID embeds the model name because the
   operator pools all models' Secrets into one listener-wide credential
   set where duplicate names collide) and mirrors it into
   `nebari-chat/nebari-chat-llm-api-keys` for the pod env. Keys activate in
   ~1 min; they won't show in the llm-keys UI (metadata ConfigMap wipe bug),
   but they work. The Secret write triggers an LLMModel reconcile, which is
   why this step runs before the route-timeout patches.

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

To rebuild from scratch, run destroy, deploy, then
`./scripts/post-recreate.sh` (re-run it if it reports anything still
pending), and re-trust the fresh root CA (Quick start steps 3–4). Note kind
mounts are fixed at cluster creation — if the repo path changes, a
destroy/deploy cycle is required.

Known from-scratch behavior: CRD ordering races (cert-manager's
`Certificate` for llm-serving-pack, `LLMModel` for llm-models) can exhaust
ArgoCD's 5-retry budget and leave apps stuck `Failed` even after the CRDs
arrive — `post-recreate.sh` re-triggers any failed app syncs automatically.
Expect a handful of apps to stay OutOfSync-but-Healthy permanently
(gateway-config — the LLM operator live-patches listeners onto the Gateway;
httproutes; the nebari-chat/nebi-pack postgres StatefulSets; nebari-root):
this drift is normal here.
