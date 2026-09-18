#!/usr/bin/env bash
# Builds the three fat jars with Maven, builds the three images, and loads them into the kind cluster.
set -euo pipefail
KIND_CLUSTER=istio-demo
KCTX="--context kind-${KIND_CLUSTER}"
# Guard: the developer's kubeconfig may point at real clusters. Never run without the kind context.
kubectl $KCTX config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null | grep -qx "kind-${KIND_CLUSTER}" \
  || { echo "FATAL: kube context kind-${KIND_CLUSTER} not found; run scripts/setup-cluster.sh first" >&2; exit 1; }
kubectl() { command kubectl $KCTX "$@"; }   # every later kubectl call in this script is pinned
cd "$(dirname "$0")/.."

# The `java` on PATH is a broken jenv shim; pin JDK 21 explicitly.
export JAVA_HOME; JAVA_HOME=$(/usr/libexec/java_home -v 21)
mvn -q -DskipTests package

for svc in portal service-a service-b; do
  docker build -q -t "istio-demo/${svc}:dev" "$svc"
done
kind load docker-image --name "$KIND_CLUSTER" istio-demo/portal:dev istio-demo/service-a:dev istio-demo/service-b:dev
echo "images built and loaded into kind-${KIND_CLUSTER}"
