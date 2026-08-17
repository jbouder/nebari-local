# nebari-local

Local Nebari cluster deployed with [NIC](https://github.com/nebari-dev/nebari-infrastructure-core)
(Nebari Infrastructure Core) using the `local` provider (kind + MetalLB).

This repo holds both the NIC config (`nebari-config.yaml`) and the GitOps tree
(`gitops/`) that ArgoCD syncs from. The repo is mounted into the kind node so
the in-cluster ArgoCD repo-server can read it via `file://`.

## Minimum specs

Everything runs in a single kind node inside the Docker Desktop VM, so the
VM's resource settings (Docker Desktop → Settings → Resources) are what
matter. Measured on the current stack (all packs + both CPU LLM models):
scheduled pod **requests** total ~11.5 CPU / ~37Gi memory, of which the two
LLM models account for 6 CPU / 28Gi (limits are heavily overcommitted:
~33 CPU / ~54Gi).

| Resource | Minimum | Comfortable | Notes |
|---|---|---|---|
| VM CPUs | 12 | 16–18 | Inference is CPU-bound: the 4B model runs 6 threads, the 35B 12. Below ~12 CPUs generations get slow and probes can flap. |
| VM memory | 40 GB | 44+ GB | Requests already sit at ~91% of a 39GB VM. **Dropping the 35B model** (delete `gitops/manifests/llm-models/qwen3-6-35b-a3b.yaml`) frees 24Gi of requests and brings the floor down to ~16 GB. |
| VM disk | 150 GB free | 250 GB | Node filesystem currently uses ~126GB: ~50GB images, ~25GB model downloads (re-downloaded after pod reschedule — emptyDir), plus volumes/build cache. |
| Host machine | 48 GB RAM Mac | 64 GB | macOS + Docker Desktop overhead on top of the VM. Apple Silicon is fine — the handful of amd64-only images are digest-pinned and run under Rosetta. |

The models are the swing factor: without any `LLMModel` CRs the whole stack
fits in roughly 8 CPUs / 16 GB VM memory.

## Quick start

From zero to a browsable cluster (each step is detailed in the sections below):

1. **Install NIC** (>= 0.12.0): `brew install nebari-dev/tap/nic`
2. **Deploy**: `nic deploy -f nebari-config.yaml` — creates the kind cluster,
   bootstraps ArgoCD, and syncs everything in `gitops/` (foundational apps +
   all software packs).
3. **Run the post-recreate script** — automates every out-of-band piece
   (CoreDNS rewrite, out-of-band secrets, CA-bundle ConfigMaps, amd64 image
   retags, Keycloak live bits, envoy extproc restart, chat-app LLM API keys).
   Idempotent; re-run it any time:
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
| Nebari Chat | https://chat.nebari.local | nebari-dev/chat-pack (frontend + ravnar backend). Two static agents backed by the cluster's LLM models (`config.inline` in `gitops/apps/nebari-chat.yaml`; per-model API keys minted by `post-recreate.sh`). SSE streams need the `BackendTrafficPolicy` timeout overrides in `gitops/manifests/chat-policies/` — carried by the `chat-policies` app because the `foundational` project rejects the `nebari-chat` namespace |
| Provenance Collector | https://provenance.nebari.local | Daily scan at 06:00; http persistence mode |
| Apps | https://apps.nebari.local | Launch static/pixi web apps (UI + API + MCP at /mcp); apps serve at `<name>.apps.nebari.local` |
| Harbor | https://harbor.nebari.local | OCI registry + Trivy scanning; "LOGIN VIA OIDC PROVIDER" (Keycloak) or `admin` with the harbor-admin secret |
| Frames | https://frames.nebari.local | Context Frames registry + remote MCP endpoint (vendored chart at `gitops/charts/nebari-frames`, tracking upstream `main` — v0.1.5 predates runtime branding — plus the local CA addition). Chart is current as of `b8db7f5`; the image runs `84cdd83` |
| LLM Serving | https://llm-keys.nebari.local | llm-d operator + API-key manager UI. **No GPUs** here, so GPU `LLMModel` CRs won't schedule (default serving image is CUDA-only). Operator, key-manager and frontend images all run ahead of the 0.1.3 chart at `sha-4cfb58c` (see [Deliberate version skew](#deliberate-version-skew)). Prereqs installed alongside: Envoy AI Gateway v0.5.0 + GIE v1.5.0 CRDs, and the foundational envoy-gateway app carries AI-extension wiring |
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

> **Route timeouts are now the operator's job** (fixed upstream in
> nebari-llm-serving-pack#168, carried by the `sha-4cfb58c` operator image
> pinned in `gitops/apps/llm-serving-pack.yaml`). The ai-gateway controller
> renders LLM routes with a default `request: 60s`, which CPU inference
> exceeds on long/thinking generations — streams died mid-token and apollo
> showed "The agent could not complete the model request". The operator now
> stamps `spec.endpoints.requestTimeout` (default `600s`) onto both generated
> AIGatewayRoutes on every reconcile, so the old `post-recreate.sh` patch loop
> is gone and there is nothing to re-apply after a model becomes Ready, an
> LLMModel spec change, or a cluster stop/start.
>
> Don't set `spec.endpoints.requestTimeout` on the `LLMModel` CRs: #168 also
> added that field to the CRD, but chart **0.1.3 ships the pre-#168 CRD**, so
> the field doesn't exist in-cluster. The operator's own `DefaultRequestTimeout`
> ("600s") applies when it's empty, which is the value we want anyway. Chart
> **0.1.4 does ship the new CRD** — lift this caveat when the pack moves to it.

> **Chart `0.1.4` is tagged but not published.** The pack's "Release Chart"
> workflow doesn't push to the index — it opens a sync PR against
> `nebari-dev/helm-repository`, and #82 is still open. Pointing
> `targetRevision` at an unpublished version makes ArgoCD fail to resolve the
> chart and **stop syncing while still reporting `Healthy`**, since the live
> workloads are untouched; the give-away is `Sync: Unknown` plus a
> `ComparisonError` condition. Before bumping any pack's chart version, confirm
> it actually exists:
> ```bash
> curl -s https://nebari-dev.github.io/helm-repository/index.yaml | \
>   yq '.entries.nebari-llm-serving[].version'
> ```
> The upgrade steps for when it lands are written out in
> `gitops/apps/llm-serving-pack.yaml`.

> **API-key metadata survives reconciles** as of nebari-llm-serving-pack#166
> (same `sha-4cfb58c` image). Previously every LLMModel reconcile wiped the
> `<model>-api-key-metadata` ConfigMap, so keys vanished from the llm-keys UI
> the moment they were minted (key creation writes the api-keys Secret, which
> triggers a reconcile) even though the credentials kept working. The
> reconciler now preserves that ConfigMap's data and manages only its labels.

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

### Branding

Every pack whose chart exposes a branding hook is set to one palette,
"Deep Blue & Teal", rendered into each app's `/config.json` at deploy time —
no image rebuilds:

| Token | Light | Dark |
|---|---|---|
| primary | `#1D4ED8` | `#60A5FA` |
| primary foreground | `#FFFFFF` | `#0B1220` |
| secondary (surface / brand) | `#E6FAF7` / `#0F766E` | `#16332F` / `#7FE9DA` |
| accent (surface / fg) | `#E8EEFC` / `#1E3A8A` | `#132039` / `#BFD4FE` |

Configured in `gitops/apps/`: `nebari-landingpage`, `nebari-chat`,
`llm-serving-pack`, `provenance-collector`, `apps-pack` (all under
`frontend.branding` / `ui.branding`), `frames-pack` (top-level `branding`),
plus `data-science-pack` for the JupyterHub + jhub-apps pages. Each chart uses a
different token vocabulary — shadcn-style `primary`/`secondary`, chat's
camelCase `bgBrandDefault`, and jhub-apps' snake_case `primary_color` — so the
same palette is expressed three ways. Harbor and Keycloak expose no branding
hook; Nebi's app supports it but its chart does not yet (nebi-pack#48).

Four things that are easy to trip over:

- **The landing page needs a manual restart after a branding-only edit.** It
  mounts `config.json` with `subPath` and its Deployment carries no
  `checksum/config` annotation, so kubelet never updates the file in place and
  ArgoCD still reports `Synced/Healthy` while nginx serves the old colors:
  ```bash
  kubectl rollout restart deploy/nebari-landing-frontend -n nebari-system
  ```
  The llm-serving, provenance and apps-pack frontends *do* set
  `checksum/config` and roll themselves — only the landing page needs this.

- **`primaryHover` / `sidebarPrimary` / `sidebarRing` are undocumented
  overrides.** The shadcn-based frontends hardcode `--primary-hover` (which
  backs every button and badge hover) and the sidebar tokens to the old Nebari
  magenta, where `primary` alone cannot reach. They apply because the runtime
  applier kebab-cases whatever keys the JSON carries with no allowlist. Fixed
  upstream in llm-serving-pack#169 and provenance-collector-pack#81 (merged),
  with nebari-landing#200 and apps-pack#7 open — drop the overrides per pack
  once a release carrying the fix is deployed. In apps-pack the symptom is
  widest: `--primary-hover` backs six components there (button, badge, switch,
  slider, checkbox, radio-group), not just button and badge.

  **Frames is the exception** — the applier added in nebari-frames#56 *derives*
  `--primary-hover` (a 15% oklab darkening in light, 18% lightening in dark) and
  `--ring` from an overridden `--primary`, so `frames-pack.yaml` sets the six
  palette tokens and nothing else. This is the shape the other packs are moving
  toward; use it as the reference when their fixes ship.

- **jhub-apps has no light/dark split.** `get_theme()` returns a single palette
  and `theme.css` emits it at `:root` with no `.dark` variant (still true in
  2026.8.1 — `primary_color_dark` is a darker *shade*, not a dark-mode value).
  No single blue satisfies both modes, so `primary_color` is set to the lighter
  `#60A5FA` for dark-mode legibility (5.94:1 on the dark surface vs 2.25:1 for
  blue-700). The cost: `hub.css` paints `.btn-primary` with the hardcoded,
  non-themeable `--light-text-color`, so light-mode primary buttons sit near
  2.4:1. Restore `#1D4ED8` in `data-science-pack.yaml` to trade back.

- **Never point provenance-collector's frontend at the `main` tag.** That image
  is built from `6d49f84` (2026-08-05) and is *older* than the `0.1.2` release
  image (`b5a6448`, 2026-08-13), so it silently reverts the header restyle. This
  pack publishes no per-commit `sha-` tags — `main`, `latest` and `0.1.2` are
  the only ones, and `latest` == `0.1.2`. Use the chart default.

### Deliberate version skew

Several places run an image from a different revision than the chart pinned
alongside it. All are intentional; revisit when the upstream branches converge
or a release carries the fix:

- **`data-science-pack`** pins the chart to `feat/user-shared-volumes` (whose
  hub image ships jhub-apps 2025.11.1) but overrides
  `jupyterhub.hub.image.tag: sha-16c1922` from the pack's `main`, which ships
  **jhub-apps 2026.7.1** — required for the profile-menu light/dark toggle. The
  branch and `main` have diverged badly (32 commits one way, 72 the other,
  including the nebi-envs stale-token fix), so switching the chart wholesale
  would regress other things. Caveat: the singleuser image still pins
  2025.11.1, so hub and singleuser are version-skewed — watch app spawning.

- **`llm-serving-pack`** keeps the chart at the `0.1.3` release but pins all
  three images (operator, key-manager, frontend) to `sha-4cfb58c` from `main`,
  for #166 (api-key metadata no longer wiped), #168 (operator-set route
  timeouts) and #169 (branding-derived hover/sidebar tokens). The chart's CRDs
  therefore lag its operator — see the `requestTimeout` note above for the one
  place that matters. This skew closes when `0.1.4` is published (it contains
  all three PRs); keep the images digest-pinned even then, since `0.1.4`
  defaults every tag to `latest` and these images are amd64-only.

- **`frames-pack`** vendors the chart from `main` rather than the `v0.1.5` tag,
  and tracks `main` for the image too. Runtime branding (nebari-frames#56) is
  unreleased, and it spans both halves: the chart renders the ConfigMap, but
  it's the Go server — not nginx — that serves `/config.json`, so a v0.1.5
  image with the main chart would mount the config and ignore it.

  Chart and image do *not* have to sit on the same commit — only on compatible
  ones. The chart is current as of `b8db7f5`; the image runs `84cdd83`
  ("Header cleanup"), which is frontend-only and touches no chart file. **The
  SPA is embedded in the Go binary**, so every web change — header, nav,
  branding applier — ships in the image and nowhere else: a UI change that
  doesn't land is almost always a stale image pin, not a chart problem. When
  re-vendoring, check `git diff <old> <new> -- chart/` and only re-copy when
  it's non-empty.

- **`nebari-landingpage`** pins a `main` commit (`8b7042a`) rather than a
  release tag, so its images float on `:latest`. That revision emits
  `landingPage.iconDark` on its NebariApp CR, which **requires
  nebari-operator >= v0.1.0** (`gitops/manifests/nebari-operator/`, bumped from
  `v0.1.0-alpha.20`). On the older CRD, ArgoCD's ServerSideApply diff fails with
  `field not declared in schema` and the whole app silently stops syncing while
  still reporting healthy.

### In-cluster access to `*.nebari.local` (required for pack OIDC)

> **All of the below is automated by `./scripts/post-recreate.sh`** (plus
> the Keycloak live bits, image retags, extproc restart, chat-app LLM API
> keys, and LLM route timeouts). The details are kept here as reference for
> what the script does and for one-off manual repair.

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
   ~1 min. They still won't show in the llm-keys UI — that's expected here,
   since the script writes the Secret directly and never calls the key-manager
   that populates the metadata ConfigMap; keys minted *through* the UI do
   persist now (#166).

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
