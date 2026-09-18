#!/usr/bin/env bash
# Runs the 10 demo scenarios (BUILD-BRIEF.md §7) against the kind cluster. Prints PASS/FAIL per scenario, exits non-zero on any FAIL.
set -euo pipefail
KIND_CLUSTER=istio-demo
KCTX="--context kind-${KIND_CLUSTER}"
# Guard: the developer's kubeconfig may point at real clusters. Never run without the kind context.
kubectl $KCTX config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null | grep -qx "kind-${KIND_CLUSTER}" \
  || { echo "FATAL: kube context kind-${KIND_CLUSTER} not found; run scripts/setup-cluster.sh first" >&2; exit 1; }
kubectl() { command kubectl $KCTX "$@"; }   # every later kubectl call in this script is pinned
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
report() { # <name> <0|1> <detail>
  if [ "$2" = 0 ]; then printf 'PASS  %-44s %s\n' "$1" "$3"; PASS=$((PASS+1)); else printf 'FAIL  %-44s %s\n' "$1" "$3"; FAIL=$((FAIL+1)); fi
}
TMP=$(mktemp -d)
PF_PID=""
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

# --- keys: scenarios 4-7 need the Signing Key, scenario 6 a foreign key. On a fresh clone recover/generate them. ---
mkdir -p keys
[ -f keys/portal.key ] || kubectl -n portal-ns get secret portal-signing-key -o jsonpath='{.data.private\.pem}' | base64 -d > keys/portal.key
[ -f keys/other.key ]  || openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out keys/other.key 2>/dev/null
VALID=$(scripts/mint-jwt.sh keys/portal.key 300)
EXPIRED=$(scripts/mint-jwt.sh keys/portal.key -120)   # -120: Envoy allows 60 s clock skew
FORGED=$(scripts/mint-jwt.sh keys/other.key 300)      # right kid and claims, wrong key

# --- helpers ---
# incurl <ns> <pod> <curl args...>: runs curl in the pod; output = body, then "__CODE__<http_code>", then "__RC__<curl exit>"
incurl() {
  local ns=$1 pod=$2; shift 2
  kubectl -n "$ns" exec "$pod" -- sh -c 'curl -s -m 10 -w "\n__CODE__%{http_code}" "$@"; rc=$?; printf "\n__RC__%s\n" "$rc"' sh "$@" 2>/dev/null || true
}
code() { sed -n 's/^__CODE__\([0-9]*\)$/\1/p' <<<"$1"; }
rc()   { sed -n 's/^__RC__\([0-9]*\)$/\1/p' <<<"$1"; }
body() { grep -v -e '^__CODE__' -e '^__RC__' <<<"$1" || true; }

SVC_A=http://service-a.svc-a-ns:8080
SVC_B=http://service-b.svc-b-ns:8080

# --- scenario 1: browser path through the ingress gateway (port-forward; NodePort 8080 is for humans) ---
kubectl -n istio-ingress port-forward svc/demo-gateway-istio 18080:80 >/dev/null 2>&1 &
PF_PID=$!
for _ in $(seq 1 30); do curl -s -o /dev/null http://localhost:18080/login 2>/dev/null && break; sleep 1; done

happy_path() { # <user> <tenant> <label>
  local jar="$TMP/jar-$1" out http sub tenant ok=1
  curl -s -o /dev/null -c "$jar" -d "username=$1&password=password" http://localhost:18080/login
  out=$(curl -s -b "$jar" -w '\n__CODE__%{http_code}' http://localhost:18080/api/hello)
  http=$(code "$out")
  sub=$(body "$out" | jq -r '.downstream.downstream.sub // empty' 2>/dev/null || true)
  tenant=$(body "$out" | jq -r '.downstream.downstream.tenant_id // empty' 2>/dev/null || true)
  [ "$http" = 200 ] && [ "$sub" = "$1" ] && [ "$tenant" = "$2" ] && ok=0
  report "$3" $ok "HTTP $http sub=$sub tenant_id=$tenant"
}
happy_path alice tenant-001 "1a alice: gateway->portal->a->b"
happy_path bob   tenant-002 "1b bob: gateway->portal->a->b"

# --- scenario 2a: in-mesh client with the wrong Service Identity -> waypoint L7 RBAC ---
OUT=$(incurl rogue-ns curl "$SVC_A/hello")
ok=1; [ "$(code "$OUT")" = 403 ] && grep -q 'RBAC: access denied' <<<"$OUT" && ok=0
report "2a rogue-ns (in mesh, wrong SA) -> a" $ok "HTTP $(code "$OUT") body=$(body "$OUT" | head -c 60)"

# --- scenario 2b: client outside the mesh, plaintext -> ztunnel L4 close under STRICT, no HTTP response ---
OUT=$(incurl default curl "$SVC_A/hello")
RC=$(rc "$OUT"); ok=1
{ [ "$RC" = 56 ] || [ "$RC" = 52 ]; } && ok=0
report "2b default (not in mesh, plaintext) -> a" $ok "curl exit=$RC (52 or 56 accepted), HTTP $(code "$OUT")"

# --- scenarios 3-7: right Service Identity (svc-a-sa) against service-b's waypoint ---
OUT=$(incurl svc-a-ns curl-as-svc-a "$SVC_B/hello")
ok=1; [ "$(code "$OUT")" = 403 ] && grep -q 'RBAC: access denied' <<<"$OUT" && ok=0
report "3  svc-a-sa, no token -> b" $ok "HTTP $(code "$OUT") (403 not 401: no token = anonymous, fails requestPrincipals)"

OUT=$(incurl svc-a-ns curl-as-svc-a -X POST -H "Authorization: Bearer $VALID" "$SVC_B/hello")
ok=1; [ "$(code "$OUT")" = 403 ] && grep -q 'RBAC: access denied' <<<"$OUT" && ok=0
report "4a svc-a-sa, valid token, POST /hello -> b" $ok "HTTP $(code "$OUT")"

OUT=$(incurl svc-a-ns curl-as-svc-a -H "Authorization: Bearer $VALID" "$SVC_B/other")
ok=1; [ "$(code "$OUT")" = 403 ] && grep -q 'RBAC: access denied' <<<"$OUT" && ok=0
report "4b svc-a-sa, valid token, GET /other -> b" $ok "HTTP $(code "$OUT")"

OUT=$(incurl svc-a-ns curl-as-svc-a -H "Authorization: Bearer $EXPIRED" "$SVC_B/hello")
ok=1; [ "$(code "$OUT")" = 401 ] && grep -q 'Jwt is expired' <<<"$OUT" && ok=0
report "5  svc-a-sa, expired token -> b" $ok "HTTP $(code "$OUT") body=$(body "$OUT" | head -c 40)"

OUT=$(incurl svc-a-ns curl-as-svc-a -H "Authorization: Bearer $FORGED" "$SVC_B/hello")
ok=1; [ "$(code "$OUT")" = 401 ] && grep -q 'Jwt verification fails' <<<"$OUT" && ok=0
report "6  svc-a-sa, forged token (same kid) -> b" $ok "HTTP $(code "$OUT") body=$(body "$OUT" | head -c 40)"

OUT=$(incurl svc-a-ns curl-as-svc-a -H "Authorization: Bearer $VALID" "$SVC_B/hello")
SUB=$(body "$OUT" | jq -r '.sub // empty' 2>/dev/null || true)
ok=1; [ "$(code "$OUT")" = 200 ] && [ "$SUB" = alice ] && ok=0
report "7  svc-a-sa, valid token, GET /hello -> b" $ok "HTTP $(code "$OUT") sub=$SUB"

echo
echo "verify: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
