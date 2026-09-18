# Istio Ambient + Internal JWT Demo

A minimal, runnable demonstration that Istio ambient mesh can own *service-to-service* authentication and authorization while a portal-minted internal JWT carries *end-user* identity down the call chain. The audience is architecture reviewers; the point is the split of responsibilities, not features.

## Language

### Identities

**Service Identity**:
The SPIFFE principal (`cluster.local/ns/<ns>/sa/<sa>`) a workload receives from ztunnel's automatic mTLS. Established and verified entirely by Istio; never touched by application code.
_Avoid_: workload identity, mTLS identity, SA token

**End-User Identity**:
The human who logged in at the Portal, carried downstream as claims in the Internal JWT (`sub`, `tenant_id`, `roles`).
_Avoid_: user principal, caller (ambiguous with Service Identity)

**Request Principal**:
Istio's name for a verified End-User Identity, expressed as `<iss>/<sub>` in `AuthorizationPolicy.requestPrincipals`.

**Tenant**:
The organization an End-User belongs to, identified by the `tenant_id` claim. The basis for future data isolation; every Internal JWT must carry it.
_Avoid_: org, account, customer

### Tokens

**Browser Session**:
The cookie-backed Spring Security session between the browser and the Portal. Terminates at the Portal and is never forwarded downstream.
_Avoid_: session token (implies it is a bearer credential)

**Internal JWT**:
A short-lived (5 min) RS256 token the Portal mints per downstream call from the logged-in user's attributes, sent as `Authorization: Bearer`. Forwarded unchanged by Service A to Service B.
_Avoid_: access token, ID token, session JWT

**Signing Key**:
The RSA key pair the Portal uses to sign Internal JWTs; mounted from a Kubernetes Secret, identified by `kid`. Its public half is the only key downstream verifiers trust.

### Mesh

**Waypoint**:
The per-namespace L7 proxy in Istio ambient that verifies Internal JWTs (`RequestAuthentication`) and enforces method/path rules. The *mandatory* verification checkpoint; the application's own check is defense in depth.

**Deny-All Baseline**:
The empty-spec `AuthorizationPolicy` present in every application namespace, so that only explicit allow rules in the *callee's* namespace admit traffic.

**Ingress Gateway**:
The Kubernetes Gateway API `Gateway` (Istio-managed) that admits browser traffic into the mesh. Lives in its own namespace, outside any Deny-All Baseline.

### Services

**Portal**:
The browser-facing service: authenticates End-Users with a form login and mints Internal JWTs. The only holder of the Signing Key.

**Service A**:
The intermediate service; verifies the Internal JWT, forwards it to Service B.

**Service B**:
The terminal service; verifies the Internal JWT and returns a greeting that echoes `sub` and `tenant_id`.

**Authorization Decision Point**:
The reserved place in Service A / Service B code where a future policy engine (e.g. OPA) would be consulted. A named hook only; no engine in this demo.
