# Istio 1.31 + kind / Kubernetes 1.35 install facts

Research for ticket `issues/02-research-istio-1-31-kind-1-35-install-facts.md`. Verified on 2026-09-17 against primary sources only (istio.io, github.com/istio/istio, github.com/istio/istio.io, github.com/kubernetes-sigs/kind, github.com/kubernetes-sigs/gateway-api, formulae.brew.sh). Anything not confirmable from those is marked **unconfirmed**.

## 1. Does Istio 1.31 exist, and does it support Kubernetes 1.35?

- **Yes.** Istio 1.31.0 is the current stable release, published 2026-08-31 and marked "Latest" on GitHub. No 1.31.x patch release exists yet, so the exact pin is `1.31.0`.
  - https://github.com/istio/istio/releases (tag `1.31.0`, 2026-08-31; `1.31.0-rc.4` on 2026-08-27 was the last pre-release)
  - https://api.github.com/repos/istio/istio/releases/latest -> `tag_name: 1.31.0`, `prerelease: false`
- The supported-releases table lists 1.31 as **currently supported**, release date Aug 27 2026, EOL ~Feb 2027, **supported Kubernetes versions 1.32, 1.33, 1.34, 1.35, 1.36**; tested-but-not-supported 1.27-1.31.
  - https://istio.io/latest/docs/releases/supported-releases/
- The 1.31 announcement states verbatim: "Istio 1.31.0 is officially supported on Kubernetes versions 1.32 to 1.36."
  - https://istio.io/latest/news/releases/1.31.x/announcing-1.31/
- Conclusion: **Istio 1.31.0 + Kubernetes 1.35 is a valid, officially supported pair.** No fallback needed. (For reference: 1.30 also supports 1.32-1.36; 1.29 supports 1.31-1.35; 1.28 is EOL and tops out at 1.34.)

## 2. Latest kind release and its Kubernetes 1.35 node image

- Latest kind release is **v0.33.0**, published 2026-08-26. It "defaults to Kubernetes 1.37.0" and ships pre-built node images for 1.37.0, 1.36.4, **1.35.8**, 1.34.11.
  - https://github.com/kubernetes-sigs/kind/releases/tag/v0.33.0
  - https://api.github.com/repos/kubernetes-sigs/kind/releases/latest -> `tag_name: v0.33.0`
- Exact image for Kubernetes 1.35 (copied from the v0.33.0 release notes):

  ```
  kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0
  ```

  - https://github.com/kubernetes-sigs/kind/releases/tag/v0.33.0
- Previous release v0.32.0 (2026-06-02) shipped `kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95`; use the v0.33.0 image with kind v0.33.0 (kind release notes publish images built for that specific kind version).
  - https://github.com/kubernetes-sigs/kind/releases/tag/v0.32.0
- Homebrew `kind` formula is at **0.33.0**, matching the latest release.
  - https://formulae.brew.sh/formula/kind
- Note: without `--image`, kind v0.33.0 creates a **1.37.0** cluster, which is *outside* Istio 1.31's supported range (1.32-1.36). `setup-cluster.sh` must pass `--image` explicitly.

> Sections 1–2 above were written by the research subagent before it was stopped. Sections 3–7 were completed by the driving session on 2026-09-17 from the locally installed `istioctl 1.31.0` release tree (`~/.local/istio-1.31.0`) and istio.io.

## 3. Install commands

- Ambient install (istio.io, 1.31 docs): `istioctl install --set profile=ambient --skip-confirmation`.
  - https://istio.io/latest/docs/ambient/install/istioctl/
- The ambient profile only sets `PILOT_ENABLE_AMBIENT`, `cni.ambient.enabled`, `ISTIO_META_ENABLE_HBONE`, and `global.variant: distroless` (local file `manifests/charts/istio-control/istio-discovery/files/profile-ambient.yaml`). It installs istiod, istio-cni (DaemonSet) and ztunnel (DaemonSet); **no ingress gateway component**.
- **kind needs no platform flag.** The platform-prerequisites page lists GKE, EKS, k3d, K3s, MicroK8s, minikube, OpenShift, Cilium; kind is absent, and the release tree has `profile-platform-{gke,k3d,k3s,microk8s,minikube,openshift}.yaml` but no kind profile. Do not pass `--set global.platform=...` or any `cni.cniBinDir` override on kind.
  - https://istio.io/latest/docs/ambient/install/platform-prerequisites/
  - https://istio.io/latest/docs/setup/platform-setup/kind/ (no Istio-specific flags; notes LoadBalancer limitation → use `kubectl port-forward` or NodePort, consistent with decision Q5)
- istioctl on macOS arm64: the user installed via `curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.31.0 TARGET_ARCH=arm64 sh -`, binary symlinked to `/opt/homebrew/bin/istioctl`; `istioctl version --remote=false` → `client version: 1.31.0` (verified locally). Homebrew `istioctl` formula version not checked (unconfirmed); the downloadIstio path is the documented one.

## 4. Gateway API CRDs

- Istio 1.31 docs install **Gateway API v1.6.0, experimental channel**, server-side:
  ```bash
  kubectl get crd gateways.gateway.networking.k8s.io &> /dev/null || \
    kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/experimental-install.yaml
  ```
  - https://istio.io/latest/docs/ambient/install/istioctl/ and https://istio.io/latest/docs/ambient/getting-started/
- Use the experimental channel as documented (the waypoint `Gateway` uses the standard `Gateway` kind, but Istio's docs pin experimental; deviating is untested). The `gateway-api/config/crd?ref=v0.5.0` string found in the release tree is a stale sample and must not be used.

## 5. `istioctl waypoint apply` (verified against local 1.31.0 binary)

- Flags: `--enroll-namespace` (labels the namespace `istio.io/use-waypoint: <name>`), `--for {all|none|service|workload}`, `--name` (default `waypoint`), `--overwrite`, `-r/--revision`, `--wait`.
- `istioctl waypoint generate -n svc-a-ns --for service` emits exactly:
  ```yaml
  apiVersion: gateway.networking.k8s.io/v1
  kind: Gateway
  metadata:
    labels:
      istio.io/waypoint-for: service
    name: waypoint
    namespace: svc-a-ns
  spec:
    gatewayClassName: istio-waypoint
    listeners:
    - name: mesh
      port: 15008
      protocol: HBONE
  ```
  Commit this (one per namespace) as `k8s/40-waypoints.yaml`, plus the namespace label `istio.io/use-waypoint: waypoint` in `00-namespaces.yaml`; `deploy.sh` may still run `istioctl waypoint apply --enroll-namespace` but the manifests are the source of truth.
- Waypoint ServiceAccount: the template `files/waypoint.yaml` creates `kind: ServiceAccount` named `{{.ServiceAccount}}`, which istiod sets to the Gateway name → SA `waypoint`, principal `cluster.local/ns/<ns>/sa/waypoint` (also confirmed from docs in research 03).

## 6. Ingress `Gateway` with `gatewayClassName: istio`

- Auto-deployed Deployment/Service/ServiceAccount are all named `<gateway-name>-istio` (template `files/kube-gateway.yaml`, `serviceAccountName: {{.ServiceAccount}}`; getting-started uses `bookinfo-gateway-istio`). Principal for `allow-gw-to-portal`: `cluster.local/ns/istio-ingress/sa/<gateway-name>-istio`; verify.sh port-forwards `svc/<gateway-name>-istio -n istio-ingress`.
  - https://istio.io/latest/docs/ambient/getting-started/deploy-sample-app/ (see research 03, question 7, for the citation detail)

## 7. Does the gateway namespace need the ambient label?

- No. The gateway pod runs its own Envoy, speaks HBONE to ambient workloads natively (`ISTIO_META_ENABLE_HBONE` from the ambient profile) and is not ztunnel-captured; the getting-started guide does not label the gateway namespace. Do **not** label `istio-ingress` ambient (research 03, question 7).

## Copy-paste for setup-cluster.sh

```bash
KIND_CLUSTER=istio-demo
KIND_NODE_IMAGE="kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0"
ISTIO_VERSION=1.31.0
GATEWAY_API_VERSION=v1.6.0
KCTX="--context kind-${KIND_CLUSTER}"

kind create cluster --name "$KIND_CLUSTER" --image "$KIND_NODE_IMAGE" --config kind-config.yaml   # extraPortMappings for browser demo
istioctl version --remote=false | grep -q "$ISTIO_VERSION" || { echo "need istioctl $ISTIO_VERSION"; exit 1; }
kubectl $KCTX get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 || \
  kubectl $KCTX apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"
istioctl install $KCTX --set profile=ambient --skip-confirmation
```
