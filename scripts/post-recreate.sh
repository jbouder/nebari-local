#!/usr/bin/env bash
# post-recreate.sh — re-apply every out-of-band piece after `nic deploy`.
#
# Idempotent: safe to re-run at any time; each step skips work already done.
# Run it right after `nic deploy -f nebari-config.yaml` finishes. It waits
# for the pieces it depends on (cert-manager root CA, Keycloak, the LLM
# operator), so a single run on a fresh cluster normally completes in one go.
#
# What still needs a human afterwards (sudo password prompts):
#   1. sudo kubectl port-forward ... 443:443        (see README "Access")
#   2. sudo security add-trusted-cert ... root CA   (fresh CA per recreate)
#   3. /etc/hosts entries (survive recreates; only when hostnames change)

set -euo pipefail

CTX=kind-nebari-local
KUBECTL="kubectl --context $CTX"
NODE=nebari-local-control-plane
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

log() { printf '\n==> %s\n' "$*"; }

wait_for() { # wait_for <tries> <sleep-secs> <desc> <cmd...>
  local tries=$1 pause=$2 desc=$3; shift 3
  for _ in $(seq 1 "$tries"); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep "$pause"
  done
  echo "TIMED OUT waiting for: $desc" >&2
  return 1
}

# ---------------------------------------------------------------- 0. argocd
log "Hard-refreshing nebari-root (file:// repo polls slowly)"
$KUBECTL -n argocd annotate applications.argoproj.io nebari-root \
  argocd.argoproj.io/refresh=hard --overwrite >/dev/null || true

kick_failed_apps() {
  # CRD ordering races (Certificate, LLMModel) exhaust ArgoCD's retry budget
  # and stay Failed even after the CRDs arrive — re-trigger those syncs.
  local failed
  failed=$($KUBECTL -n argocd get applications.argoproj.io -o json |
    jq -r '.items[] | select(.status.operationState.phase=="Failed") | .metadata.name')
  for app in $failed; do
    echo "  re-triggering failed sync: $app"
    $KUBECTL -n argocd patch applications.argoproj.io "$app" --type merge \
      -p '{"operation":{"initiatedBy":{"username":"post-recreate"},"sync":{"prune":true}}}' >/dev/null || true
  done
}

# ------------------------------------------------------- 1. coredns rewrite
log "CoreDNS rewrite: *.nebari.local -> envoy gateway service"
GW_SVC=$($KUBECTL -n envoy-gateway-system get svc \
  -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].metadata.name}')
if [ -z "$GW_SVC" ]; then echo "gateway service not found yet" >&2; exit 1; fi

if $KUBECTL -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' |
    grep -q 'nebari\\\.local'; then
  echo "  already present"
else
  $KUBECTL -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' |
    awk -v svc="$GW_SVC" '
      /^[[:space:]]*kubernetes / && !done {
        print "    rewrite stop {"
        print "       name regex (.*\\.)?nebari\\.local " svc ".envoy-gateway-system.svc.cluster.local"
        print "       answer auto"
        print "    }"
        done=1
      }
      { print }' > "$WORKDIR/Corefile"
  $KUBECTL -n kube-system create configmap coredns \
    --from-file=Corefile="$WORKDIR/Corefile" --dry-run=client -o yaml |
    $KUBECTL apply -f - >/dev/null
  $KUBECTL -n kube-system rollout restart deploy/coredns >/dev/null
  echo "  applied + coredns restarted"
fi

# -------------------------------------------------- 2. out-of-band secrets
# `create` (not apply) so existing values are never overwritten.
log "Out-of-band secrets"
$KUBECTL create namespace harbor 2>/dev/null || true
$KUBECTL create namespace nebari-chat 2>/dev/null || true

$KUBECTL -n keycloak create secret generic postgresql-credentials \
  --from-literal=postgres-password="$(openssl rand -hex 16)" \
  --from-literal=user-password="$(openssl rand -hex 16)" 2>/dev/null \
  && echo "  created keycloak/postgresql-credentials" || echo "  keycloak/postgresql-credentials exists"

$KUBECTL -n keycloak create secret generic keycloak-postgresql-credentials \
  --from-literal=password="$(openssl rand -hex 16)" 2>/dev/null \
  && echo "  created keycloak/keycloak-postgresql-credentials" || echo "  keycloak/keycloak-postgresql-credentials exists"

$KUBECTL -n harbor create secret generic harbor-admin \
  --from-literal=HARBOR_ADMIN_PASSWORD="$(openssl rand -base64 24)" 2>/dev/null \
  && echo "  created harbor/harbor-admin" || echo "  harbor/harbor-admin exists"

$KUBECTL -n nebari-chat create secret generic nebari-chat-postgres-password \
  --from-literal=password="$(openssl rand -hex 16)" 2>/dev/null \
  && echo "  created nebari-chat/nebari-chat-postgres-password" || echo "  nebari-chat/nebari-chat-postgres-password exists"

kick_failed_apps

# ------------------------------------------------------------ 3. ca bundle
log "CA-bundle ConfigMaps (waiting for root CA from cert-manager)"
wait_for 90 10 "nebari-local-root-ca secret" \
  $KUBECTL -n cert-manager get secret nebari-local-root-ca

$KUBECTL -n cert-manager get secret nebari-local-root-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > "$WORKDIR/root-ca.pem"
cat /etc/ssl/cert.pem "$WORKDIR/root-ca.pem" > "$WORKDIR/ca-bundle.crt"
for ns in nebi nebari-chat frames envoy-gateway-system; do
  $KUBECTL create namespace "$ns" 2>/dev/null || true
  $KUBECTL -n "$ns" create configmap nebari-local-ca-bundle \
    --from-file=ca-bundle.crt="$WORKDIR/ca-bundle.crt" --dry-run=client -o yaml |
    $KUBECTL apply --server-side --force-conflicts -f - >/dev/null
  echo "  $ns/nebari-local-ca-bundle applied"
done
# Keep a copy for the manual workstation-trust step.
cp "$WORKDIR/root-ca.pem" /tmp/nebari-local-root-ca.pem
echo "  root CA saved to /tmp/nebari-local-root-ca.pem (trust it: see README)"

# --------------------------------------------- 4. amd64 image pulls/retags
log "amd64 digest pulls for label-constrained charts (provenance)"
retag() { # retag <image> <tag> <amd64-digest>
  if docker exec "$NODE" ctr -n k8s.io images ls -q | grep -q "^$1:$2$"; then
    echo "  $1:$2 already present"
  else
    docker exec "$NODE" ctr -n k8s.io images pull --platform linux/amd64 "$1@$3" >/dev/null
    docker exec "$NODE" ctr -n k8s.io images tag --force "$1@$3" "$1:$2" >/dev/null
    echo "  $1:$2 retagged from amd64 digest"
  fi
}
retag quay.io/nebari/provenance-collector 0.1.2 \
  sha256:c18bcf8a8c70bc60425b9293d0bbea3da857ae39f2a16d2b8aaee2ca447c7668
retag ghcr.io/nebari-dev/provenance-collector-pack/frontend 0.1.2 \
  sha256:08c87115afef393f498220b8fe43c338a511798d6183527cfce9acbf3d92f9b9

# --------------------------------------------------- 5. keycloak live bits
# The operator does not create these (upstream gaps): the frames audience
# mapper (frames rejects tokens whose aud lacks its SPA client) and the
# debug-cli client (password grant for CLI token minting).
log "Keycloak live bits (waiting for Keycloak + operator-created clients)"
wait_for 120 10 "keycloak pod ready" sh -c \
  "$KUBECTL -n keycloak get pod keycloak-keycloakx-0 -o jsonpath='{.status.containerStatuses[0].ready}' | grep -q true"

KC_EXEC="$KUBECTL -n keycloak exec keycloak-keycloakx-0 -- /opt/keycloak/bin/kcadm.sh"
ADMIN_PW=$($KUBECTL -n keycloak get secret keycloak-admin-credentials \
  -o jsonpath='{.data.admin-password}' | base64 -d)
$KC_EXEC config credentials --server http://localhost:8080 \
  --realm master --user admin --password "$ADMIN_PW" >/dev/null

FRAMES_SPA=frames-frames-nebari-frames-spa
echo "  waiting for operator-created frames clients (up to 15 min)..."
wait_for 90 10 "frames SPA client in realm" sh -c \
  "$KC_EXEC get clients -r nebari -q clientId=$FRAMES_SPA --fields clientId | grep -q $FRAMES_SPA"

$KC_EXEC create clients -r nebari -s clientId=debug-cli -s enabled=true \
  -s protocol=openid-connect -s publicClient=true \
  -s directAccessGrantsEnabled=true -s standardFlowEnabled=false \
  2>/dev/null && echo "  created debug-cli client" || echo "  debug-cli client exists"

SCOPE_ID=$($KC_EXEC get client-scopes -r nebari --fields id,name |
  grep -B1 '"name" *: *"frames-audience"' | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p')
if [ -z "$SCOPE_ID" ]; then
  $KC_EXEC create client-scopes -r nebari -s name=frames-audience \
    -s protocol=openid-connect \
    -s 'attributes={"include.in.token.scope":"false","display.on.consent.screen":"false"}' >/dev/null
  SCOPE_ID=$($KC_EXEC get client-scopes -r nebari --fields id,name |
    grep -B1 '"name" *: *"frames-audience"' | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p')
  $KC_EXEC create client-scopes/"$SCOPE_ID"/protocol-mappers/models -r nebari \
    -s name=frames-audience -s protocol=openid-connect \
    -s protocolMapper=oidc-audience-mapper \
    -s "config={\"included.client.audience\":\"$FRAMES_SPA\",\"access.token.claim\":\"true\",\"id.token.claim\":\"false\"}" >/dev/null
  echo "  created frames-audience scope + mapper"
else
  echo "  frames-audience scope exists"
fi

for CID in "$FRAMES_SPA" frames-frames-nebari-frames-device apollo-desktop debug-cli; do
  CUUID=$($KC_EXEC get clients -r nebari -q clientId="$CID" --fields id |
    sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p')
  if [ -n "$CUUID" ]; then
    $KC_EXEC update clients/"$CUUID"/default-client-scopes/"$SCOPE_ID" -r nebari 2>/dev/null || true
    echo "  frames-audience attached to $CID"
  else
    echo "  WARNING: client $CID not found; re-run this script once it exists"
  fi
done

kick_failed_apps

# ----------------------------------------- 6. envoy proxy extproc sidecar
# The ai-gateway mutating webhook injects the extproc sidecar at pod
# CREATION — a proxy pod that predates envoy-ai-gateway 500s all llm traffic.
log "Envoy proxy extproc sidecar"
PROXY_DEPLOY=$($KUBECTL -n envoy-gateway-system get deploy \
  -l gateway.envoyproxy.io/owning-gateway-name=nebari-gateway -o name | head -1)
if $KUBECTL -n envoy-gateway-system get pods \
    -l gateway.envoyproxy.io/owning-gateway-name=nebari-gateway \
    -o jsonpath='{.items[*].spec.initContainers[*].name}' | grep -q ai-gateway-extproc; then
  echo "  extproc sidecar already injected"
else
  $KUBECTL -n envoy-gateway-system rollout restart "$PROXY_DEPLOY" >/dev/null
  $KUBECTL -n envoy-gateway-system rollout status "$PROXY_DEPLOY" --timeout=180s >/dev/null
  echo "  proxy restarted (extproc injected). Restart your 443 port-forward if it was running."
fi

# ------------------------------------------------- 7. llm route timeouts
# ai-gateway defaults LLM routes to 60s; CPU generations exceed that.
# Patch sticks until the LLMModel spec changes. Routes appear only once a
# model is Ready, so patch whatever exists and report what's still pending.
log "LLM route timeouts (600s)"
MODELS=$($KUBECTL -n nebari-llm-serving-system get llmmodels \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
for m in $MODELS; do
  for r in "$m-internal" "$m-external"; do
    if ! $KUBECTL -n nebari-llm-serving-system get aigatewayroute "$r" >/dev/null 2>&1; then
      echo "  $r: not created yet (model not Ready) — re-run this script later"
      continue
    fi
    CUR=$($KUBECTL -n nebari-llm-serving-system get aigatewayroute "$r" \
      -o jsonpath='{.spec.rules[0].timeouts.request}')
    if [ "$CUR" = "600s" ]; then
      echo "  $r: already 600s"
    else
      $KUBECTL -n nebari-llm-serving-system patch aigatewayroute "$r" --type=json \
        -p '[{"op":"add","path":"/spec/rules/0/timeouts","value":{"request":"600s"}}]' >/dev/null
      echo "  $r: patched to 600s"
    fi
  done
done

log "Done. Remaining manual (sudo) steps — run in your own terminal:"
cat <<EOF
  sudo kubectl --context $CTX port-forward -n envoy-gateway-system svc/$GW_SVC 443:443
  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/nebari-local-root-ca.pem
EOF
