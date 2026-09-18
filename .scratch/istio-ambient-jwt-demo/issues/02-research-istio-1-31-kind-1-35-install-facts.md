# 02: Research: Istio 1.31 + kind/K8s 1.35 install facts

Type: research
Status: resolved
Blocked by:

## Question

Verify against primary sources (istio.io release notes/docs, istio/istio GitHub, kind releases/GitHub, kubernetes-sigs/gateway-api) everything `scripts/setup-cluster.sh` and `k8s/40-waypoints.yaml` / `k8s/50-gateway.yaml` need to be correct on the first try:

1. Does Istio **1.31** exist as a stable release? Exact latest patch version and its supported Kubernetes versions (does it list 1.35?). If 1.31 does not exist or does not support 1.35, report the closest valid pair and say so plainly.
2. Latest **kind** release and whether it ships a node image for Kubernetes **1.35** (exact `kindest/node:v1.35.x@sha256:...` tag from the kind release notes). If not, closest available.
3. Install commands: `istioctl install --set profile=ambient` for 1.31 (any extra flags needed on kind, e.g. `--set values.cni.cniBinDir`? none expected, confirm). How to install istioctl 1.31 on macOS arm64 (brew formula version vs. `downloadIstio` script with `ISTIO_VERSION`).
4. Gateway API CRD version Istio 1.31 requires/bundles for ambient (`kubectl apply -f .../gateway-api/releases/...` exact URL and version; standard vs experimental channel).
5. `istioctl waypoint apply` in 1.31: flags for namespace enrollment (`--enroll-namespace`), the resulting `Gateway` manifest shape (gatewayClassName `istio-waypoint`, listener), the label it sets (`istio.io/use-waypoint`), and the **ServiceAccount name** the waypoint deployment runs as (expected `waypoint`, confirm) so L4 allow rules can reference `cluster.local/ns/<ns>/sa/<name>`.
6. Gateway API `Gateway` with `gatewayClassName: istio`: the **ServiceAccount name** of the auto-deployed gateway (expected `<gateway-name>-istio`) and its Service name, so `allow-gw-to-portal` can reference the right principal and verify.sh can port-forward to the right Service.
7. Whether the auto-deployed ingress gateway needs its namespace labelled `istio.io/dataplane-mode: ambient` to reach ambient workloads over HBONE with its own identity, or whether it does so natively in 1.31.

Write findings to `research/istio-1-31-kind-1-35-install-facts.md`, each claim cited with a URL. Then append the summary under `## Answer` in this file and set `Status: resolved`. Do **not** edit `map.md`.

## Answer

Subagent covered questions 1–2 before being stopped by the user; the driving session completed 3–7 from the local istioctl 1.31.0 release tree and istio.io. Full note: `research/istio-1-31-kind-1-35-install-facts.md`.

1. Istio **1.31.0** (2026-08-31) is current stable; officially supports K8s 1.32–1.36, so **1.35 is a supported pair**.
2. kind **v0.33.0**; K8s 1.35 image `kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0`. Default without `--image` is 1.37 (outside Istio's range): always pass `--image`.
3. `istioctl install --set profile=ambient --skip-confirmation`; **no kind platform flag** (kind absent from platform-prerequisites). Ambient profile ships no ingress gateway.
4. Gateway API **v1.6.0 experimental** channel, `kubectl apply --server-side`.
5. `istioctl waypoint apply --enroll-namespace --for service`; generated `Gateway` named `waypoint`, class `istio-waypoint`, HBONE 15008; SA = `waypoint`.
6. Ingress `Gateway` (class `istio`) → Deployment/Service/SA `<name>-istio`; principal `cluster.local/ns/istio-ingress/sa/<name>-istio`.
7. Gateway namespace must **not** be ambient-labelled; the gateway speaks HBONE natively.
