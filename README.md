# Istio Ambient + Internal JWT Demo

A minimal, runnable demonstration that **Istio ambient mesh owns service-to-service authentication and authorization** while a **portal-minted Internal JWT carries end-user identity** down the call chain. The audience is architecture reviewers; the point is the split of responsibilities, not features.

- Three Spring Boot 4.1.1 services with **zero mesh code**: `portal` (form login, mints the JWT), `service-a` (verifies, forwards), `service-b` (verifies, answers).
- Istio 1.31 ambient on kind / Kubernetes 1.35: ztunnel enforces mTLS + L4 identity, per-namespace waypoints verify the JWT and enforce method/path.
- `scripts/verify.sh` proves 10 scenarios (happy paths, wrong identity, no mesh, no token, wrong method/path, expired token, forged token).

Vocabulary (Service Identity, End-User Identity, Internal JWT, Waypoint, Deny-All Baseline, ...) is defined in [CONTEXT.md](CONTEXT.md). Design rationale is in [docs/adr](docs/adr). The decision-complete build brief is [BUILD-BRIEF.md](BUILD-BRIEF.md).

## Quick start

Prerequisites (macOS, verified 2026-09-17): kind v0.33.0, `istioctl` 1.31.0, Docker CLI with a running engine (colima works), JDK 21 at `/usr/libexec/java_home -v 21`, Maven 3.9, `jq`, `openssl`, `xxd`.

```bash
scripts/gen-keys.sh        # RSA Signing Key pair + JWKS -> k8s/60-secrets.yaml, k8s/32-request-authentication.yaml
scripts/setup-cluster.sh   # kind cluster "istio-demo" (K8s 1.35.8) + Gateway API v1.6.0 + Istio 1.31.0 ambient
scripts/build-and-load.sh  # mvn package, docker build x3, kind load
scripts/deploy.sh          # kubectl apply -f k8s/, wait for gateway/waypoints/apps/test pods
scripts/verify.sh          # 10 scenarios, PASS/FAIL each, non-zero exit on any FAIL
```

Browser demo: open <http://localhost:8080/api/hello>, log in as `alice` / `password` (tenant-001) or `bob` / `password` (tenant-002). Expected response:

```json
{"user":"alice","via":"portal","downstream":{"via":"service-a","sub":"alice","tenant_id":"tenant-001",
  "downstream":{"via":"service-b","greeting":"Hello, alice!","sub":"alice","tenant_id":"tenant-001","roles":["USER"]}}}
```

Teardown: `kind delete cluster --name istio-demo`.

**Safety:** every script pins `--context kind-istio-demo` and fails fast if that context does not exist. The developer's current kubeconfig context is never used or changed (`setup-cluster.sh` restores it after `kind create cluster`).

## Topology

```
 browser
   │ HTTP :8080 (kind extraPortMapping -> NodePort 30080) or kubectl port-forward
   ▼
 ┌────────────────────────── istio-ingress ns (NOT ambient-labelled) ──────────────────────────┐
 │ Gateway "demo-gateway" (gatewayClassName: istio) -> Deployment/Service/SA "demo-gateway-istio" │
 └───────────────────────────────────────┬──────────────────────────────────────────────────────┘
                                         │ HBONE, identity cluster.local/ns/istio-ingress/sa/demo-gateway-istio
 ┌── portal-ns (ambient) ────────────────▼──────────────────────────────────────────────────────┐
 │ ztunnel: PeerAuth STRICT · deny-all · allow-gw-to-portal (L4)                                 │
 │ portal (SA portal-sa) — form login, mints Internal JWT, calls service-a                        │
 └───────────────────────────────────────┬──────────────────────────────────────────────────────┘
                                         │ HBONE, identity portal-sa, Authorization: Bearer <Internal JWT>
 ┌── svc-a-ns (ambient, use-waypoint) ───▼──────────────────────────────────────────────────────┐
 │ waypoint (SA waypoint): RequestAuthentication + allow-portal-to-a (L7: principal+JWT+GET /hello) │
 │      │ HBONE, identity cluster.local/ns/svc-a-ns/sa/waypoint                                   │
 │ ztunnel: STRICT · deny-all · allow-waypoint-to-a (L4)                                           │
 │ service-a (SA svc-a-sa) — resource server, forwards the same JWT to service-b                   │
 └───────────────────────────────────────┬──────────────────────────────────────────────────────┘
                                         │ HBONE, identity svc-a-sa, same Bearer token
 ┌── svc-b-ns (ambient, use-waypoint) ───▼──────────────────────────────────────────────────────┐
 │ waypoint (SA waypoint): RequestAuthentication + allow-a-to-b (L7: principal+JWT+GET /hello)     │
 │ ztunnel: STRICT · deny-all · allow-waypoint-to-b (L4)                                           │
 │ service-b (SA svc-b-sa) — resource server, returns greeting with sub + tenant_id                │
 └────────────────────────────────────────────────────────────────────────────────────────────────┘
 rogue-ns (ambient, deny-all, no allow anywhere) — scenario 2a client: in the mesh, wrong identity
 default  (NOT labelled)                          — scenario 2b client: outside the mesh, plaintext
```

Every segment marked HBONE is mTLS established by ztunnel (or the gateway's / waypoint's own Envoy) from the pod's ServiceAccount. No application code is involved in any of it.

## One request, hop by hop

`GET /api/hello` from a logged-in browser:

| # | Hop | Enforcer | What is checked | If it fails you see |
|---|---|---|---|---|
| 1 | browser -> Gateway | Gateway (Envoy) | HTTPRoute `portal-ns/portal` matches; no auth at the edge | 404 from the gateway |
| 2 | Gateway -> portal pod | `portal-ns` ztunnel | mTLS STRICT; `allow-gw-to-portal`: source principal is `cluster.local/ns/istio-ingress/sa/demo-gateway-istio` | 503 from the gateway (upstream reset) |
| 3 | portal | Spring Security | Browser Session cookie -> `alice`; mints Internal JWT (`iss`, `aud`, `sub`, `tenant_id`, `roles`, 5 min, `kid: portal-key-1`) | 302 to `/login` |
| 4 | portal -> svc-a waypoint | `svc-a-ns` waypoint (Envoy) | `RequestAuthentication portal-jwt`: signature vs inline JWKS, `iss`, `aud`, `exp`; `allow-portal-to-a`: principal `portal-sa` **and** `requestPrincipals https://portal.internal/*` **and** `GET /hello` | 401 `Jwt is expired` / `Jwt verification fails`; 403 `RBAC: access denied` |
| 5 | waypoint -> service-a pod | `svc-a-ns` ztunnel | `allow-waypoint-to-a`: source principal is the waypoint's SA (the waypoint does not impersonate the caller) | connection closed, waypoint returns 503 |
| 6 | service-a | Spring resource server | Verifies the same JWT again with the public key (defense in depth), `aud`, `roles -> ROLE_USER`; Authorization Decision Point asserts `tenant_id` | 401 / 403 from the app |
| 7 | service-a -> svc-b waypoint | `svc-b-ns` waypoint | as hop 4 with principal `svc-a-sa` and `allow-a-to-b` | as hop 4 |
| 8 | waypoint -> service-b pod | `svc-b-ns` ztunnel | `allow-waypoint-to-b` | as hop 5 |
| 9 | service-b | Spring resource server | as hop 6; returns `greeting`, `sub`, `tenant_id`, `roles` | as hop 6 |

The Browser Session cookie stops at hop 3. The Internal JWT is created at hop 3 and forwarded unchanged through hop 9. Service Identity is established fresh at every HBONE hop and never appears in application code.

## Who provides which security property

| Property | Istio (ambient) | Application code |
|---|---|---|
| Service identity (SPIFFE, per ServiceAccount) | ztunnel issues and verifies certs | none |
| Transport encryption | ztunnel mTLS, `PeerAuthentication STRICT` per namespace | none |
| Service-level authorization (who may call whom) | ztunnel L4 `AuthorizationPolicy` (`principals`) + waypoint `principals` | none |
| Method / path authorization | waypoint `AuthorizationPolicy` with `targetRefs` (`methods`, `paths`) | none |
| User authentication | none | portal form login (`InMemoryUserDetailsManager`) |
| User identity propagation | waypoint `RequestAuthentication` verifies the JWT; `requestPrincipals` requires it | portal mints (`TokenMinter`), service-a forwards `jwt.getTokenValue()` |
| Tenant claim | waypoint verifies signature only | portal `TENANTS` map -> `tenant_id` claim |
| In-app claim access | none | `@AuthenticationPrincipal Jwt` in service-a / service-b |
| Authorization Decision Point | none | `HelloController.authorize(Jwt, action)` in service-a and service-b |

## What verify.sh proves

| # | Client | Call | Expected | Observed 2026-09-17 |
|---|---|---|---|---|
| 1a | host via port-forward, logged in as alice | `GET /api/hello` | 200, `sub=alice`, `tenant_id=tenant-001` at service-b | PASS |
| 1b | same as bob | `GET /api/hello` | 200, `bob` / `tenant-002` | PASS |
| 2a | `curl` pod in `rogue-ns` (in mesh, wrong identity) | `GET service-a:8080/hello` | 403 `RBAC: access denied` from the waypoint | PASS |
| 2b | `curl` pod in `default` (not in mesh, plaintext) | same | no HTTP response; curl exit 56 or 52 (ztunnel L4 close under STRICT) | PASS, exit 56 |
| 3 | `curl-as-svc-a` (SA svc-a-sa), no token | `GET service-b:8080/hello` | 403 `RBAC: access denied` (not 401: a missing token is anonymous and fails `requestPrincipals`) | PASS |
| 4a | same, valid token | `POST /hello` | 403 `RBAC: access denied` | PASS |
| 4b | same, valid token | `GET /other` | 403 `RBAC: access denied` | PASS |
| 5 | same, token with `exp = now - 120 s` | `GET /hello` | 401 `Jwt is expired` | PASS |
| 6 | same, token signed with `keys/other.key`, same `kid` | `GET /hello` | 401 `Jwt verification fails` | PASS |
| 7 | same, valid token | `GET /hello` | 200, `sub=alice` (isolates 3–6 from identity problems) | PASS |

Tokens for 4–7 come from `scripts/mint-jwt.sh keys/portal.key <ttl>`; the expired token uses `-120` because Envoy allows 60 s clock skew.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Pod traffic is plaintext; `istioctl ztunnel-config workload` shows `TCP` instead of `HBONE`; policies have no effect | Namespace lacks `istio.io/dataplane-mode: ambient` | Label the namespace (`k8s/00-namespaces.yaml`); pods are captured in place, no restart needed |
| Allow policy has no effect, traffic still denied | `AuthorizationPolicy` in the wrong namespace: policies apply to workloads in **their own** namespace (the callee's) | Move it to the callee's namespace |
| Everything to a workload is denied even from the right identity; ztunnel logs `explicitly denied` | L7 fields (`methods`, `paths`, `requestPrincipals`, headers) on a `selector` / no-`targetRefs` policy: ztunnel cannot evaluate them and **fails safe to DENY** | Attach L7 policies to the waypoint with `targetRefs` (`kind: Service` or `kind: Gateway`) |
| Waypoint answers 401 `Jwks remote fetch is failed` or istiod logs JWKS fetch errors | `jwksUri` used and istiod (in `istio-system`) cannot reach the JWKS endpoint, e.g. because the issuer sits behind a Deny-All Baseline | This demo uses inline `jwks` (ADR-0003); if you switch to `jwksUri`, allow `cluster.local/ns/istio-system/sa/istiod` to reach it |
| Requests **time out** instead of getting 403 / a reset | A CNI `NetworkPolicy` is dropping packets before ztunnel sees them | Check `kubectl get networkpolicy -A`; Istio denials are fast (403 or RST), never timeouts |
| Client gets a 503 / upstream error **from the waypoint** instead of `RBAC: access denied`; destination ztunnel logs `connection closed due to policy rejection` | The waypoint's ServiceAccount is not allowed at the destination ztunnel; the Deny-All Baseline blocks the waypoint -> pod hop | Keep `allow-waypoint-to-a` / `allow-waypoint-to-b` (`principals: cluster.local/ns/<ns>/sa/waypoint`, no L7 fields) |
| Happy path returns 401 **from the application** although the waypoint accepted the token | `forwardOriginalToken` is false (the default): the waypoint strips the `Authorization` header | Set `forwardOriginalToken: true` in every `RequestAuthentication` |
| 401 `Jwks doesn't have key to match kid or alg from Jwt` | JWT header `kid` differs from the JWKS `kid`. Spring Security 7's `NimbusJwtEncoder.withKeyPair` defaults `kid` to a key thumbprint | Set `keyID("portal-key-1")` on the `RSAKey.Builder` (see `SecurityConfig.jwtEncoder`) or in the `JwsHeader` |
| `istioctl install` warns about an unsupported Kubernetes version, or ambient behaves oddly | kind v0.33.0 defaults to Kubernetes **1.37**, outside Istio 1.31's supported range (1.32–1.36) | Always pass `--image kindest/node:v1.35.8@sha256:...` (`scripts/setup-cluster.sh` does) |
| Gateway stays `Programmed=False`, message `no instances found for hostname demo-gateway-istio...` | A Service named `demo-gateway-istio` was created by hand before Istio's controller ran; Istio does not merge a selector into it | Delete the hand-made Service and let Istio create it; pin the NodePort afterwards with a patch (`scripts/deploy.sh` does) |
| `http://localhost:8080` unreachable but port-forward works | The gateway Service's `http` nodePort is not 30080 (Istio picks a random one) | Re-run `scripts/deploy.sh`, which patches the nodePort; or use `kubectl --context kind-istio-demo -n istio-ingress port-forward svc/demo-gateway-istio 18080:80` |

Useful commands (all pinned to the kind context):

```bash
istioctl --context kind-istio-demo ztunnel-config workload          # HBONE vs TCP, waypoint per workload
istioctl --context kind-istio-demo ztunnel-config policy            # L4 policies as ztunnel sees them
kubectl --context kind-istio-demo -n istio-system logs ds/ztunnel | grep -i 'policy rejection'
kubectl --context kind-istio-demo -n svc-b-ns logs deploy/waypoint  # waypoint access log incl. 401/403 bodies
```

## JWKS in production, and key rotation

This demo inlines the JWKS in `RequestAuthentication.jwks` (ADR-0003) because the portal sits behind a Deny-All Baseline and istiod, not the waypoint, fetches `jwksUri`. Production options:

1. **Portal serves `/.well-known/jwks.json`** and `RequestAuthentication` uses `jwksUri: http://portal.portal-ns.svc:8080/.well-known/jwks.json`. `portal-ns` then needs an L4 allow for `cluster.local/ns/istio-system/sa/istiod` (istiod is the fetcher). Rotation: portal publishes old + new keys, switches signing `kid`, drops the old key after the token TTL (5 min here); istiod refreshes the JWKS on its own schedule (`PILOT_JWT_PUB_KEY_REFRESH_INTERVAL`, default 20 min), so keep both keys published at least that long.
2. **Dedicated JWKS service** outside any deny-all (e.g. `jwks-ns`), fed from the same Secret; same rotation as 1, fewer policy exceptions for istiod.
3. **External IdP** (Keycloak, Entra ID, Okta) as issuer; `jwksUri` points at the IdP, `issuer`/`audiences` change accordingly; the IdP owns rotation.

Rotation with the **inline** option used here: run `scripts/gen-keys.sh` after moving `keys/` aside to mint a new pair; edit `k8s/32-request-authentication.yaml` so `jwks.keys` contains **both** the old and the new key (different `kid`); `kubectl apply`; roll the portal Secret and set the new `kid` in `TokenMinter.KEY_ID`; after the token TTL, remove the old key from `jwks` and re-apply. The waypoint matches `kid` only when both sides carry one, so mismatched `kid` values fail closed with `Jwks doesn't have key to match kid or alg from Jwt`.

## Authorization Decision Point

`HelloController.authorize(Jwt jwt, String action)` in [service-a](service-a/src/main/java/demo/servicea/HelloController.java) and [service-b](service-b/src/main/java/demo/serviceb/HelloController.java) is the single place where a policy engine would be consulted. Today it only asserts that `tenant_id` is present and throws `AccessDeniedException` (HTTP 403) otherwise.

Plugging in OPA later: run OPA as a sidecar or a `opa.opa-ns` service, and have `authorize` `POST` `{"input":{"sub":..,"tenant_id":..,"roles":[..],"action":"read:hello","resource":"/hello"}}` to `/v1/data/demo/allow`; deny unless the result is `true`. Because the mesh already guarantees *which service* is calling and the waypoint already guarantees the token is genuine, OPA only has to reason about *what this user may do in this tenant*.

## Running locally without Istio

Each module has a `local` profile (ports 8080 / 8081 / 8082, keys from `./keys`). From the repo root, after `scripts/gen-keys.sh`:

```bash
export JAVA_HOME=$(/usr/libexec/java_home -v 21)
(cd service-b && mvn -q spring-boot:run -Dspring-boot.run.profiles=local) &
(cd service-a && mvn -q spring-boot:run -Dspring-boot.run.profiles=local) &
(cd portal    && mvn -q spring-boot:run -Dspring-boot.run.profiles=local) &
```

Then either log in in the browser at <http://localhost:8080/api/hello>, or call a resource server directly with a shell-minted token:

```bash
curl -s -H "Authorization: Bearer $(scripts/mint-jwt.sh keys/portal.key 300)" http://localhost:8082/hello | jq .
```

Without Istio there is no waypoint, so only the in-app checks apply: a request with no token gets 401 from Spring (not 403), and there is no method/path or caller-identity enforcement. That difference is the point of the demo.

## Repository layout

```
pom.xml                        Maven parent (spring-boot-starter-parent 4.1.1, Java 21), modules below
portal/ service-a/ service-b/  Spring Boot modules, one Dockerfile each (eclipse-temurin:21-jre)
k8s/00-namespaces.yaml         istio-ingress (dataplane-mode: none), portal-ns, svc-a-ns, svc-b-ns, rogue-ns
k8s/10..12-*.yaml              ServiceAccount + Deployment + Service per app, key mounts under /etc/portal-keys
k8s/20-peer-authentication     STRICT per app namespace
k8s/30-deny-all.yaml           Deny-All Baseline x4 + waypoint-scoped allow-nothing x2
k8s/31-authorization-policies  the five per-hop allows
k8s/32-request-authentication  GENERATED: JWT rules with inline JWKS, forwardOriginalToken: true
k8s/40-waypoints.yaml          Gateway "waypoint" (istio-waypoint) in svc-a-ns and svc-b-ns
k8s/50-gateway.yaml            ingress Gateway "demo-gateway" + HTTPRoute -> portal
k8s/60-secrets.yaml            GENERATED: Signing Key Secret + public-key ConfigMaps (demo only)
k8s/90-test-pods.yaml          curl pods for verify.sh
scripts/                       gen-keys, mint-jwt, setup-cluster, build-and-load, deploy, verify, kind-config.yaml
docs/adr/                      architectural decisions; docs/superpowers/plans/ the implementation plan
```

### Demo-only shortcuts, deliberately not production-grade

- The private Signing Key is committed in `k8s/60-secrets.yaml` so the demo is reproducible.
- CSRF is disabled on the portal so `verify.sh` can log in with curl.
- Passwords are plaintext (`{noop}`) in memory; there is no user store, no DB, no observability, no OPA.
