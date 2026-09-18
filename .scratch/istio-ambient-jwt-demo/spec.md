# Spec: Istio Ambient + Spring Boot Internal JWT Propagation Demo

Requirements as given by the user (translated from the original Chinese brief, content preserved). Decisions taken while wayfinding are **not** restated here; see `map.md` → Decisions so far. The final build brief is assembled by the last ticket on the map.

## Goal

A minimal, runnable demo proving the architecture "Istio ambient owns service-to-service authN/authZ; a portal-minted internal JWT propagates end-user identity". Audience: architecture reviewers. Code must be **readable, runnable, verifiable**; feature richness is not a goal.

## Stack

- Java 21, Spring Boot 3.3+, Maven multi-module
- Kubernetes 1.29+ (local: kind)
- Istio 1.24+ in **ambient mode** (no sidecars)
- No service registry / gateway frameworks (no Nacos, no Spring Cloud Gateway). Service discovery is plain K8s DNS.

## Architecture

Three Spring Boot services, **each in its own namespace**:

| Service | Namespace | ServiceAccount | Role |
|---|---|---|---|
| `portal` | `portal-ns` | `portal-sa` | Browser-facing; username/password login; mints internal JWT |
| `service-a` | `svc-a-ns` | `svc-a-sa` | Intermediate; calls service-b |
| `service-b` | `svc-b-ns` | `svc-b-sa` | Terminal; returns a greeting |

Call chain: `browser → ingress gateway → portal → service-a → service-b`

## Responsibility split (core constraint, do not deviate)

| Concern | Owner | Where |
|---|---|---|
| Who is the end user | portal application code | Spring Security form login |
| Which service is calling | Istio ztunnel auto-mTLS + SPIFFE | **zero Java code** |
| Who may call whom (service level) | `AuthorizationPolicy` (L4, enforced by ztunnel) | YAML |
| Who may call which endpoint (method/path) | `AuthorizationPolicy` (L7, enforced by waypoint) | YAML |
| How end-user identity reaches downstream | portal-minted internal JWT | code + `RequestAuthentication` |

**Hard rule: the Java code of all three services must contain nothing related to mTLS, certificates, SPIFFE, or ServiceAccount tokens.** Service-to-service calls are plain HTTP. If any of that appears in code, the design has been misunderstood.

## Internal JWT

### Issuance (portal)

- Portal holds an RSA key pair (RS256). Keys are mounted from a K8s Secret and read from files; **never hard-coded in source or application.yaml**.
- Successful login creates a browser session (ordinary cookie). **The browser session token is never forwarded downstream.**
- On every downstream call, portal **freshly signs** a short-lived JWT (TTL 5 min) from the logged-in user's attributes and sends it as `Authorization: Bearer <token>`.
- Use Nimbus JOSE (`com.nimbusds:nimbus-jose-jwt`) or Spring Security's `JwtEncoder`; do not hand-assemble base64.

Claims:

```json
{
  "iss": "https://portal.internal",
  "aud": "internal-services",
  "sub": "alice",
  "tenant_id": "tenant-001",
  "roles": ["USER"],
  "iat": 1700000000,
  "exp": 1700000300
}
```

`tenant_id` is mandatory: the target architecture is multi-tenant and this claim is the basis for later data isolation.

### Verification (two layers)

**Layer 1: waypoint (mandatory checkpoint).** Deploy a waypoint in `svc-a-ns` and in `svc-b-ns`. `RequestAuthentication` verifies signature and issuer; `AuthorizationPolicy` with `requestPrincipals` requires a valid JWT. Requests without a valid token are rejected before reaching the application.

**Layer 2: in-app (defense in depth + claim access).** service-a / service-b use `spring-boot-starter-oauth2-resource-server` pointed at the same public key, parse `sub` / `tenant_id` / `roles` into the `SecurityContext`, and business code reads them via `@AuthenticationPrincipal Jwt`. Side benefit: services run and debug standalone without Istio.

### JWKS distribution (known pitfall)

`RequestAuthentication.jwksUri` is fetched by **istiod**, not the data plane. If it points at portal inside `portal-ns`, the deny-all there blocks istiod: every request gets 401 with no obvious log line.

**This demo inlines the static public key** in the `jwks:` field:

```yaml
spec:
  jwtRules:
    - issuer: "https://portal.internal"
      audiences: ["internal-services"]
      jwks: |
        {"keys":[{"kty":"RSA","kid":"portal-key-1","n":"...","e":"AQAB"}]}
```

The README must include a section on three production alternatives and their costs: (1) portal serves `/.well-known/jwks.json` and `portal-ns` allows istiod's ServiceAccount; (2) host JWKS on a separate service outside deny-all; (3) external IdP provides JWKS. Explain key rotation under each.

## Istio configuration requirements

1. All three namespaces labelled `istio.io/dataplane-mode: ambient`.
2. **One deny-all per namespace** (empty `spec: {}`). Do not use a mesh-wide deny-all in `istio-system`.
3. Allow policies live in the **callee's** namespace:
   - `allow-gw-to-portal` → `portal-ns`
   - `allow-portal-to-a` → `svc-a-ns`, principal `cluster.local/ns/portal-ns/sa/portal-sa`
   - `allow-a-to-b` → `svc-b-ns`, principal `cluster.local/ns/svc-a-ns/sa/svc-a-sa`
4. `allow-a-to-b` uses L7 rules: `methods: ["GET"]`, `paths: ["/hello"]`, bound to the waypoint via `targetRefs` → Service. **Never `selector`**: an L7 policy evaluated by ztunnel fails safe to DENY.
5. Authorization rules require **both** service identity (`principals`) **and** user identity (`requestPrincipals`).
6. `PeerAuthentication` mode `STRICT`.
7. Waypoints generated with `istioctl waypoint apply`; commit the manifests, not just the command.
8. If `svc-b-ns` has workload-level L4 policies, also allow the waypoint's own ServiceAccount.

## Deliverables

```
.
├── README.md
├── pom.xml
├── portal/
├── service-a/
├── service-b/
├── k8s/
│   ├── 00-namespaces.yaml
│   ├── 10-portal.yaml            # SA + Deployment + Service
│   ├── 11-service-a.yaml
│   ├── 12-service-b.yaml
│   ├── 20-peer-authentication.yaml
│   ├── 30-deny-all.yaml          # one per namespace
│   ├── 31-authorization-policies.yaml
│   ├── 32-request-authentication.yaml
│   ├── 40-waypoints.yaml
│   ├── 50-gateway.yaml
│   └── 60-secrets.yaml           # RSA private key (demo only, clearly labelled)
└── scripts/
    ├── gen-keys.sh               # generate RSA pair + emit JWK JSON
    ├── setup-cluster.sh          # kind create + istioctl install --set profile=ambient
    ├── build-and-load.sh         # mvn package + docker build + kind load
    ├── deploy.sh
    └── verify.sh
```

## `verify.sh` scenarios (more important than business code; each prints PASS/FAIL)

1. **Happy path**: log in to portal → call `/api/hello` → response shows username and tenant_id propagated all the way to service-b.
2. **Service identity blocked**: curl pod in `default` ns → `service-a.svc-a-ns:8080/hello` → expect `RBAC: access denied`.
3. **User identity blocked**: pod in `svc-a-ns` running as `svc-a-sa` calls service-b **without JWT** → expect 401/403 (correct service identity alone is not enough).
4. **L7 path blocked**: valid identity + valid JWT → `POST /hello` or `GET /other` on service-b → expect denial.
5. **Expired token**: JWT with past `exp` → rejected by waypoint.
6. **Forged token**: JWT signed with a different key pair → rejected.

## README requirements

- ASCII architecture diagram: three namespaces, SA identities, mTLS segments, waypoint positions.
- Full request walk-through from browser to service-b, hop by hop: "what is checked here, by whom".
- Table of security properties provided by Istio vs. by application code.
- "Troubleshooting" section covering at least: missing ambient label; AuthorizationPolicy in the wrong namespace; L7 policy with `selector` → fail-safe DENY; JWKS unreachable; CNI NetworkPolicy blocking (manifests as timeout, not 403).
- The JWKS production-options comparison and key-rotation notes above.

## Explicit non-goals

- No database, no frontend framework (Spring Security default login page is fine).
- No OPA integration (later phase); leave a named "authorization decision point" in code and mark it in the README.
- No observability configuration.
- No production-grade key management.

## Style

- One-sentence "why it is written this way" comment on every key config and non-obvious code block, especially where something looks simplifiable but isn't.
- No over-abstraction: no interfaces/factories/strategies for the demo's sake.
- Total Java under 500 lines.
