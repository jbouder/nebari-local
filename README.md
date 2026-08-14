# nebari-local

Local Nebari cluster deployed with [NIC](https://github.com/nebari-dev/nebari-infrastructure-core)
(Nebari Infrastructure Core) using the `local` provider (kind + MetalLB).

This repo holds both the NIC config (`nebari-config.yaml`) and the GitOps tree
(`gitops/`) that ArgoCD syncs from. The repo is mounted into the kind node so
the in-cluster ArgoCD repo-server can read it via `file://`.

## Deploy

```bash
nic deploy -f nebari-config.yaml
```

This creates a kind cluster named `nebari-local`, installs MetalLB, bootstraps
ArgoCD, and commits the foundational app-of-apps manifests (cert-manager,
Envoy Gateway, Keycloak, PostgreSQL, nebari-operator, etc.) into `gitops/`.

## Kubeconfig

```bash
nic kubeconfig -f nebari-config.yaml
```

## Access

```bash
# ArgoCD
kubectl port-forward svc/argocd-server -n argocd 8080:443
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

# Keycloak
kubectl port-forward svc/keycloak -n keycloak 8081:80
```

## Teardown

```bash
nic destroy -f nebari-config.yaml
```
