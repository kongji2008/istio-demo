---
status: accepted
---
# The ingress Gateway lives in its own namespace, not in portal-ns

Every application namespace carries a Deny-All Baseline `AuthorizationPolicy`. A Gateway API `Gateway` deployed into `portal-ns` would have that namespace-wide deny enforced by the gateway's own Envoy, rejecting browser traffic before it enters the mesh. The Gateway is therefore deployed in a dedicated `istio-ingress` namespace with no deny-all, and `portal-ns` admits it explicitly by the gateway's ServiceAccount principal.

## Considered Options

- **Gateway in `portal-ns`**: rejected for the reason above; would need a carve-out that undermines the "one deny-all per namespace" rule the demo teaches.
- **Classic Istio `Gateway` + `VirtualService` with `istio-ingressgateway`**: rejected; the ambient profile ships no ingress gateway component, and Gateway API is the documented path for ambient.
