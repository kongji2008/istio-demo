#!/usr/bin/env bash
# Creates the kind cluster (Kubernetes 1.35.8) and installs Gateway API v1.6.0 + Istio 1.31.0 ambient profile.
set -euo pipefail
KIND_CLUSTER=istio-demo
KCTX="--context kind-${KIND_CLUSTER}"
# Guard: the developer's kubeconfig may point at real clusters. This script only ever creates and talks to the kind cluster.
kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER" \
  && { echo "FATAL: kind cluster ${KIND_CLUSTER} already exists; run 'kind delete cluster --name ${KIND_CLUSTER}' first" >&2; exit 1; }
cd "$(dirname "$0")/.."

# kind v0.33.0 defaults to Kubernetes 1.37, which Istio 1.31 does not support: always pass --image.
KIND_NODE_IMAGE="kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0"
ISTIO_VERSION=1.31.0
GATEWAY_API_VERSION=v1.6.0

istioctl version --remote=false | grep -q "$ISTIO_VERSION" \
  || { echo "FATAL: need istioctl ${ISTIO_VERSION} (curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -)" >&2; exit 1; }

# kind switches the current kubeconfig context to the new cluster; remember the developer's context and put it back at the end.
PREV_CTX=$(command kubectl config current-context 2>/dev/null || true)
kind create cluster --name "$KIND_CLUSTER" --image "$KIND_NODE_IMAGE" --config scripts/kind-config.yaml
kubectl() { command kubectl $KCTX "$@"; }   # every later kubectl call in this script is pinned

# Gateway API CRDs, experimental channel, server-side apply: exactly as the Istio 1.31 ambient docs do.
kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 \
  || kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"

# Ambient profile installs istiod, istio-cni and ztunnel; no ingress gateway component (the Gateway API creates ours). kind needs no platform flag.
istioctl install $KCTX --set profile=ambient --skip-confirmation

kubectl -n istio-system rollout status deploy/istiod --timeout=300s
kubectl -n istio-system rollout status ds/ztunnel --timeout=300s
kubectl -n istio-system rollout status ds/istio-cni-node --timeout=300s
kubectl get pods -n istio-system
[ -n "$PREV_CTX" ] && command kubectl config use-context "$PREV_CTX" >/dev/null && echo "restored current context to ${PREV_CTX}"
echo "cluster ${KIND_CLUSTER} ready (context kind-${KIND_CLUSTER})"
