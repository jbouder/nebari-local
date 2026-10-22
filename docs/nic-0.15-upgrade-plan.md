# NIC v0.15.0 in-place upgrade plan

Bring the running `nebari-local` cluster up to NIC v0.15.0's foundational
software **without recreating it**, so the in-cluster data (21 PVCs: Keycloak,
Harbor, JupyterHub homes, Nebi, chat, analytics, LGTM…) survives.

## Why not `nic deploy --regen-apps`

The v0.15 upgrade notes say local clusters must be recreated and in-place
upgrades should run `nic deploy --regen-apps`. Neither fits here:

- **Recreate** wipes every PVC.
- **`--regen-apps`** can't target this repo's layout. v0.15 replaced
  `git_repository:` with `repository:`, and its `local` provider has no
  subdirectory option (`path` is the repo directory). It would render the
  foundational tree at the repo root, while ArgoCD's `nebari-root` and every
  pack live under `gitops/`. The `existing` provider has a `path` but rejects
  `file://` URLs.

So the v0.12.0 → v0.15.0 template delta (`pkg/argocd/templates`, 14 files) is
ported to `gitops/` by hand.

## Delta and what we do with it

| Template change | Action |
|---|---|
| `apps/nebari-operator.yaml`: kustomize → Helm chart `quay.io/nebari/charts/nebari-operator` `0.2.0` | **Port** (stage 1) |
| `values/nebari-operator/base.yaml` (new) | **Port** (stage 1) |
| `manifests/nebari-operator/` deleted | **Delete** (stage 1) |
| `apps/envoy-gateway.yaml`: `gateway-helm` v1.6.2 → v1.9.1 (Gateway API CRDs v1.6.1) | **Port** (stage 2) |
| MetalLB app/config/values deleted | **Skip.** Needs the kind host-port mappings, which only exist on a new cluster. MetalLB and the sudo port-forward stay. |
| `manifests/networking/envoyproxy.yaml` NodePort patch | **Skip.** Only rendered when the gateway is published on host ports (same reason). |
| Keycloak secret keys templated (`KeycloakAdminPasswordKey`, …) | **No-op.** Renders to the same names. |
| Longhorn SecurityPolicy | **No-op.** No Longhorn locally. |

`nebari-config.yaml` moves to the v0.15 schema (`repository.local`) so
`nic destroy` / `nic deploy --dry-run` validate. **Don't run `nic deploy`
against the existing cluster**: it would write manifests at the repo root.

## Stage 1: nebari-operator 0.2.0

- The chart ships the NebariApp CRD as a template with
  `helm.sh/resource-policy: keep`, so ArgoCD adopts the existing CRD and the
  15 NebariApps survive.
- The `foundational` AppProject lives only in the cluster (NIC derives its
  `sourceRepos` from the rendered app templates at deploy time), so it has to
  allow the chart repo out of band:
  `kubectl -n argocd patch appproject foundational --type json -p '[{"op":"add","path":"/spec/sourceRepos/-","value":"quay.io/nebari/charts"}]'`.
  Without it the app fails with `InvalidSpecError` and the old operator keeps
  running.
- The kustomize install's `Namespace` gets pruned and recreated
  (`CreateNamespace=true`). It only holds the operator. If the app stays
  `OutOfSync`, sync it again.
- The local kustomize pin existed for the `landingPage.iconDark/iconLight`
  CRD fields (v0.1.0); 0.2.0 includes them.
- **Behaviour change:** `auth.groups` is enforced at the gateway, so
  non-members get a 403. Affected: `apps/app-web-terminal` (`admin`) and
  `monitoring/lgtm-pack-nebari-lgtm-pack` (`admin`, `viewer`). The `groups`
  claim now carries full paths, users are logged out once, and every app's
  Keycloak client is reprovisioned once.

Verify: operator pod Running on 0.2.0; all NebariApps Ready; sign in at
nebari.local, Grafana and web-terminal as `admin`.

## Stage 2: Envoy Gateway v1.9.1

- Only after stage 1. Operator 0.2.0 writes the `https://` issuer that gateway
  sign-in needs on EG 1.9.1.
- Expect about 30s of rejected config while the proxies roll (we have
  SecurityPolicies). The port-forward dies when the proxy pod restarts, so
  restart it.
- **Risk:** Envoy AI Gateway v0.5.0 (llm-serving-pack) has only been tested
  against EG 1.6.x / Gateway API 1.4.x. The AI-extension wiring in
  `apps/envoy-gateway.yaml` stays as is.
- Gateway API CRD upgrades don't roll back cleanly, so treat this stage as
  forward-only.

Verify: envoy-gateway and the proxy pods Running; every pack hostname loads;
`llm-keys.nebari.local` loads and an LLM route still answers through the AI
Gateway ext_proc.

## Rollout mechanics

ArgoCD reads `main` over `file://`. Work happens on `chore/nic-0.15`; each
stage is merged to `main` on its own, followed by a hard refresh of
`nebari-root`. The pre-upgrade state is tagged `pre-nic-0.15`.

## Docs

README: NIC >= 0.15.0, the `repository:` config block, the in-place caveat
above, and the fact that `/usr/local/bin/nic` must not shadow the Homebrew
binary.
