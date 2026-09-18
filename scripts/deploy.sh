#!/usr/bin/env bash
# Applies k8s/ in filename order and waits for the gateway, waypoints, apps and test pods to be Ready.
set -euo pipefail
KIND_CLUSTER=istio-demo
KCTX="--context kind-${KIND_CLUSTER}"
# Guard: the developer's kubeconfig may point at real clusters. Never run without the kind context.
kubectl $KCTX config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null | grep -qx "kind-${KIND_CLUSTER}" \
  || { echo "FATAL: kube context kind-${KIND_CLUSTER} not found; run scripts/setup-cluster.sh first" >&2; exit 1; }
kubectl() { command kubectl $KCTX "$@"; }   # every later kubectl call in this script is pinned
cd "$(dirname "$0")/.."

[ -f k8s/60-secrets.yaml ] || { echo "FATAL: k8s/60-secrets.yaml missing; run scripts/gen-keys.sh" >&2; exit 1; }
kubectl apply -f k8s/   # kubectl applies a directory in filename order: 00-namespaces first

# Istio provisions the gateway and waypoint Deployments asynchronously: wait for them to exist, then to roll out.
wait_deploy() {
  local ns=$1 name=$2
  for _ in $(seq 1 60); do kubectl -n "$ns" get deploy "$name" >/dev/null 2>&1 && break; sleep 2; done
  kubectl -n "$ns" rollout status "deploy/$name" --timeout=300s
}
wait_deploy istio-ingress demo-gateway-istio
wait_deploy svc-a-ns waypoint
wait_deploy svc-b-ns waypoint
wait_deploy portal-ns portal
wait_deploy svc-a-ns service-a
wait_deploy svc-b-ns service-b
kubectl -n rogue-ns wait --for=condition=Ready pod/curl --timeout=120s
kubectl -n default  wait --for=condition=Ready pod/curl --timeout=120s
kubectl -n svc-a-ns wait --for=condition=Ready pod/curl-as-svc-a --timeout=120s

kubectl get pods -A -l 'app in (portal,service-a,service-b)' -o wide
kubectl get gateway -A
kubectl get authorizationpolicies -A
echo "deployed; browser: http://localhost:8080/  (or: kubectl $KCTX -n istio-ingress port-forward svc/demo-gateway-istio 18080:80)"
