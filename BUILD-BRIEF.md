# Build Brief: Istio Ambient + Spring Boot Internal JWT Propagation Demo

This is the **decision-complete** brief for one implementation session. Every choice below is settled; the implementer builds, does not decide. Where a fact was verified against a primary source, the research note holding the citation is named. Vocabulary follows [CONTEXT.md](./CONTEXT.md); architectural rationale is in [docs/adr](./docs/adr).

Planning artifacts: [.scratch/istio-ambient-jwt-demo/map.md](./.scratch/istio-ambient-jwt-demo/map.md) (decisions index), [spec.md](./.scratch/istio-ambient-jwt-demo/spec.md) (original requirements), `research/*.md` (cited findings). Do not change them; they are the record.

---

## 0. Hard rules

1. **Language**: every artifact (code, comments, YAML, scripts, README) is English.
2. **kubectl context**: every script pins `--context kind-istio-demo`. The developer's kubeconfig current context may be a **real cluster**. Scripts must fail fast if the kind cluster does not exist; never run a bare `kubectl`.
3. **Zero mesh code in Java**: no mTLS, certificates, SPIFFE, or ServiceAccount-token handling in any service. Service-to-service calls are plain HTTP to K8s DNS names.
4. **Java under 500 lines total**, no interfaces/factories/strategies. One-sentence "why" comment on each non-obvious block and each key config.
5. Non-goals stand: no DB, no frontend framework, no OPA (leave a named Authorization Decision Point hook), no observability, no production key management.

## 1. Versions (verified; research 02, 04)

| Component | Pin | Note |
|---|---|---|
| Kubernetes | **1.35.8** via `kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0` | kind v0.33.0 defaults to 1.37, which Istio 1.31 does not support: always pass `--image`. |
| kind | v0.33.0 (installed) | |
| Istio | **1.31.0** (istioctl installed at `/opt/homebrew/bin/istioctl`) | Officially supports K8s 1.32–1.36. |
| Gateway API CRDs | **v1.6.0, experimental channel**, `kubectl apply --server-side` | As the 1.31 ambient docs do. |
| Java | 21 (`/usr/libexec/java_home -v 21`; do not rely on `java` on PATH, the jenv shim is broken) | |
| Spring Boot | **4.1.1** (latest GA on Maven Central, 2026-09-17) | Spring Security 7, Jackson 3. |
| Maven | 3.9.16 (installed) | |
| Container runtime | colima (running, 4 CPU / 8 GiB); Docker CLI 29 | No Docker Desktop. |

## 2. Topology

```
 browser
   │ HTTP :8080 (kind extraPortMapping) / kubectl port-forward
   ▼
 ┌────────────────────────── istio-ingress ns (NOT ambient-labelled) ──────────────────────────┐
 │ Gateway "demo-gateway" (gatewayClassName: istio) → Deployment/Service/SA "demo-gateway-istio" │
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
 │ service-a (SA svc-a-sa) — resource server, forwards JWT to service-b                            │
 └───────────────────────────────────────┬──────────────────────────────────────────────────────┘
                                         │ HBONE, identity svc-a-sa, same Bearer token
 ┌── svc-b-ns (ambient, use-waypoint) ───▼──────────────────────────────────────────────────────┐
 │ waypoint (SA waypoint): RequestAuthentication + allow-a-to-b (L7: principal+JWT+GET /hello)     │
 │ ztunnel: STRICT · deny-all · allow-waypoint-to-b (L4)                                           │
 │ service-b (SA svc-b-sa) — resource server, returns greeting with sub + tenant_id                │
 └────────────────────────────────────────────────────────────────────────────────────────────────┘
 rogue-ns (ambient, deny-all, no allow anywhere) — scenario 2a client
 default (NOT labelled)                          — scenario 2b client
```

Per-hop identity table (research 03) is the ground truth for every policy below:

| Hop | Enforcer | Source principal seen | Binding |
|---|---|---|---|
| gateway → portal pod | portal-ns ztunnel | `cluster.local/ns/istio-ingress/sa/demo-gateway-istio` | L4, no `targetRefs` |
| portal → svc-a waypoint | waypoint | `cluster.local/ns/portal-ns/sa/portal-sa` + JWT | L7, `targetRefs: Service service-a` |
| svc-a waypoint → service-a pod | svc-a-ns ztunnel | `cluster.local/ns/svc-a-ns/sa/waypoint` | L4 |
| service-a → svc-b waypoint | waypoint | `cluster.local/ns/svc-a-ns/sa/svc-a-sa` + JWT | L7, `targetRefs: Service service-b` |
| svc-b waypoint → service-b pod | svc-b-ns ztunnel | `cluster.local/ns/svc-b-ns/sa/waypoint` | L4 |

## 3. Repository layout (final)

```
.
├── README.md
├── BUILD-BRIEF.md                 # this file
├── CONTEXT.md · docs/adr/         # existing; do not edit
├── pom.xml                        # parent: spring-boot-starter-parent 4.1.1, modules below, java.version 21
├── portal/                        # Dockerfile + src
├── service-a/
├── service-b/
├── k8s/
│   ├── 00-namespaces.yaml         # istio-ingress, portal-ns, svc-a-ns, svc-b-ns, rogue-ns (+labels)
│   ├── 10-portal.yaml             # SA portal-sa + Deployment + Service (8080), key Secret mount
│   ├── 11-service-a.yaml          # SA svc-a-sa + Deployment + Service, public-key ConfigMap mount
│   ├── 12-service-b.yaml          # SA svc-b-sa + Deployment + Service
│   ├── 20-peer-authentication.yaml
│   ├── 30-deny-all.yaml           # portal-ns, svc-a-ns, svc-b-ns, rogue-ns + 2 waypoint-scoped allow-nothing
│   ├── 31-authorization-policies.yaml
│   ├── 32-request-authentication.yaml
│   ├── 40-waypoints.yaml
│   ├── 50-gateway.yaml            # Gateway demo-gateway + HTTPRoute → portal
│   ├── 60-secrets.yaml            # GENERATED by gen-keys.sh; demo-only banner; private key + public PEM ConfigMap
│   └── 90-test-pods.yaml          # curl pods for verify.sh (rogue-ns, default, svc-a-ns as svc-a-sa)
└── scripts/
    ├── kind-config.yaml           # extraPortMappings 30080→8080 for browser demo
    ├── gen-keys.sh
    ├── mint-jwt.sh
    ├── setup-cluster.sh
    ├── build-and-load.sh
    ├── deploy.sh
    └── verify.sh
```

Additions vs. the original brief, all approved: `mint-jwt.sh`, `kind-config.yaml`, `90-test-pods.yaml`, namespace `rogue-ns`, second demo user `bob`.

## 4. Java

### Common
- Parent POM `spring-boot-starter-parent:4.1.1`, `<java.version>21</java.version>`, modules `portal`, `service-a`, `service-b`. Dockerfiles: `eclipse-temurin:21-jre` base, copy the fat jar, `EXPOSE 8080`.
- Each service: `server.port=8080`, endpoint `GET /hello` (services) or `GET /api/hello` (portal), plus Actuator is **not** needed; use a plain `GET /healthz` returning 200 for probes (avoid the actuator starter to keep Java small). Health endpoints must be reachable without a JWT (permitAll) and are the only unauthenticated paths on service-a/b.

### portal
- Starters: `spring-boot-starter-web`, `spring-boot-starter-security`, `spring-boot-starter-restclient` (**required in Boot 4** for `RestClient.Builder`), `spring-security-oauth2-jose` (for `NimbusJwtEncoder`). No Nimbus direct dependency needed.
- Security: form login with the default Spring login page; **CSRF disabled** with comment "demo: login is driven by curl in verify.sh; CSRF is out of this demo's scope". `/api/**` requires authentication; everything else is login flow.
- Users: in-memory. Two records `alice / password / tenant-001 / [USER]` and `bob / password / tenant-002 / [USER]`. `InMemoryUserDetailsManager` cannot carry `tenant_id`, so keep a tiny `Map<String,String> TENANTS` beside it with a comment; do not build a custom `UserDetails` class.
- Keys: read `file:/etc/portal-keys/private.pem` (PKCS#8 `BEGIN PRIVATE KEY`) and `file:/etc/portal-keys/public.pem` (SPKI `BEGIN PUBLIC KEY`) via `@Value("${portal.jwt.private-key}") RSAPrivateKey` / `RSAPublicKey` (Boot converts PEM resources). Paths come from `application.yaml` properties so local runs can point at `./keys/`. **Never inline key material.**
- Encoder bean (research 04):
  ```java
  JWK jwk = new RSAKey.Builder(pub).privateKey(priv).keyID("portal-key-1").build(); // kid MUST match the JWKS in RequestAuthentication; Security 7's withKeyPair defaults kid to a thumbprint and the waypoint then 401s
  return new NimbusJwtEncoder(new ImmutableJWKSet<>(new JWKSet(jwk)));
  ```
- `GET /api/hello`: read `Authentication`, mint per call:
  `iss=https://portal.internal`, `aud=["internal-services"]`, `sub=username`, `tenant_id`, `roles=["USER"]`, `iat=now`, `exp=now+300s`; header `JwsHeader.with(RS256).keyId("portal-key-1").type("JWT")`. Call `http://service-a.svc-a-ns.svc.cluster.local:8080/hello` (property `portal.downstream.service-a-url`) with `Authorization: Bearer <token>`. Never forward the session cookie. Return `{"via":"portal","user":"<sub>","downstream":<service-a JSON>}`.

### service-a and service-b
- Starters: `spring-boot-starter-web`, `spring-boot-starter-security-oauth2-resource-server` (**new Boot 4 name**; the old `spring-boot-starter-oauth2-resource-server` is deprecated). service-a also `spring-boot-starter-restclient`.
- `application.yaml`:
  ```yaml
  spring.security.oauth2.resourceserver.jwt:
    public-key-location: file:/etc/portal-keys/public.pem   # SPKI PEM only; PKCS#1 "BEGIN RSA PUBLIC KEY" will not parse
    audiences: internal-services                            # adds the aud validator; issuer-uri must NOT be set (Boot would attempt OIDC discovery)
    authorities-claim-name: roles
    authority-prefix: ROLE_
  ```
  Issuer is enforced by the waypoint; in-app `iss` check is optional and, if added, done with a `JwtIssuerValidator` on a custom `JwtDecoder`. Keep it out to save lines unless trivial.
- Security config: `/hello` → `hasRole("USER")`, `/healthz` → permitAll, `oauth2ResourceServer(jwt)`. Stateless.
- **Authorization Decision Point**: one method `void authorize(Jwt jwt, String action)` in each service's controller class (or a tiny `AuthorizationDecisionPoint` component, max ~15 lines) that today only asserts `tenant_id` is present and returns; comment: "OPA/policy engine integration point; see README". Called at the top of `/hello`.
- service-a `GET /hello`: `@AuthenticationPrincipal Jwt jwt`; forward the **same** bearer token (from `jwt.getTokenValue()`) to `http://service-b.svc-b-ns.svc.cluster.local:8080/hello`; return `{"via":"service-a","sub":..,"tenant_id":..,"downstream":<service-b JSON>}`.
- service-b `GET /hello`: return `{"via":"service-b","greeting":"Hello, <sub>!","sub":..,"tenant_id":..,"roles":[..]}`.
- Response shape decision: verify.sh asserts with `jq` on `.downstream.downstream.sub == "alice"` and `.downstream.downstream.tenant_id == "tenant-001"` (and `bob` / `tenant-002`).

## 5. Kubernetes manifests

### 00-namespaces.yaml
- `istio-ingress`: **no** ambient label (gateway speaks HBONE natively; labelling is wrong). Optionally `istio.io/dataplane-mode: none` to make it explicit.
- `portal-ns`, `svc-a-ns`, `svc-b-ns`, `rogue-ns`: `istio.io/dataplane-mode: ambient`.
- `svc-a-ns`, `svc-b-ns` additionally `istio.io/use-waypoint: waypoint` (what `--enroll-namespace` would set).
- `default` is left untouched.

### 10/11/12 workloads
- SA per service; Deployment 1 replica; `containerPort: 8080`; readiness on `/healthz`; Service `port: 8080`, `appProtocol: http` (helps the waypoint pick HTTP).
- portal mounts Secret `portal-signing-key` at `/etc/portal-keys` (`private.pem`, `public.pem`). service-a/b mount ConfigMap `portal-public-key` at `/etc/portal-keys` (`public.pem`). Both objects come from `60-secrets.yaml`.
- Images `istio-demo/portal:dev`, `istio-demo/service-a:dev`, `istio-demo/service-b:dev`, `imagePullPolicy: IfNotPresent` (kind load).

### 20-peer-authentication.yaml
One `PeerAuthentication` per application namespace (`portal-ns`, `svc-a-ns`, `svc-b-ns`, `rogue-ns`), `mtls.mode: STRICT`, no selector. Enforced by ztunnel; namespace scope is sufficient (research 03 §6).

### 30-deny-all.yaml
- Four empty-spec `AuthorizationPolicy` (`portal-ns`, `svc-a-ns`, `svc-b-ns`, `rogue-ns`). Comment: enforced by ztunnel only; waypoints ignore policies without `targetRefs`.
- Two **waypoint-scoped allow-nothing** policies (`svc-a-ns`, `svc-b-ns`): `targetRefs: [{group: gateway.networking.k8s.io, kind: Gateway, name: waypoint}]`, `action: ALLOW`, no rules. Comment: gives the waypoint a default-deny too, without a mesh-wide policy in istio-system.

### 31-authorization-policies.yaml (research 03 implications 2–4, 8)
| Name | Namespace | Binding | Rule |
|---|---|---|---|
| `allow-gw-to-portal` | portal-ns | none (ztunnel L4) | `from.source.principals: ["cluster.local/ns/istio-ingress/sa/demo-gateway-istio"]` |
| `allow-waypoint-to-a` | svc-a-ns | none (ztunnel L4) | `principals: ["cluster.local/ns/svc-a-ns/sa/waypoint"]` — **no** L7 fields, do **not** list portal-sa here |
| `allow-portal-to-a` | svc-a-ns | `targetRefs: [{group: "", kind: Service, name: service-a}]` | `principals: ["cluster.local/ns/portal-ns/sa/portal-sa"]`, `requestPrincipals: ["https://portal.internal/*"]`, `to.operation.methods: ["GET"]`, `paths: ["/hello"]` |
| `allow-waypoint-to-b` | svc-b-ns | none (ztunnel L4) | `principals: ["cluster.local/ns/svc-b-ns/sa/waypoint"]` |
| `allow-a-to-b` | svc-b-ns | `targetRefs: [{group: "", kind: Service, name: service-b}]` | `principals: ["cluster.local/ns/svc-a-ns/sa/svc-a-sa"]`, `requestPrincipals: ["https://portal.internal/*"]`, `methods: ["GET"]`, `paths: ["/hello"]` |

Health probes: kubelet probes are not mesh traffic in ambient (ztunnel exempts them), so no allow is needed for `/healthz`.

Comments to include verbatim in spirit: "L7 fields on a `selector` policy are evaluated by ztunnel and fail safe to DENY; hence `targetRefs`"; "the waypoint does not impersonate the caller, so ztunnel sees the waypoint's SA".

### 32-request-authentication.yaml
One per waypoint namespace, `targetRefs: [{group: "", kind: Service, name: service-a|service-b}]`:
```yaml
jwtRules:
  - issuer: "https://portal.internal"
    audiences: ["internal-services"]
    forwardOriginalToken: true     # REQUIRED: default strips the token and the in-app resource server would 401 on the happy path
    jwks: |
      {"keys":[{"kty":"RSA","use":"sig","alg":"RS256","kid":"portal-key-1","n":"<from gen-keys.sh>","e":"AQAB"}]}
```
`gen-keys.sh` rewrites the `jwks` line (or the whole file from a template); the committed copy carries a placeholder and a comment "run scripts/gen-keys.sh".

### 40-waypoints.yaml
Verbatim `istioctl waypoint generate --for service` output for `svc-a-ns` and `svc-b-ns`: `Gateway` named `waypoint`, label `istio.io/waypoint-for: service`, `gatewayClassName: istio-waypoint`, listener `mesh` port 15008 protocol HBONE. The SA name `waypoint` is what the L4 policies depend on.

### 50-gateway.yaml
`Gateway demo-gateway` in `istio-ingress`, `gatewayClassName: istio`, listener HTTP :80, `allowedRoutes.namespaces.from: All`; `HTTPRoute portal` in `portal-ns`, `parentRefs` → `istio-ingress/demo-gateway`, backend `portal:8080`. Istio creates Deployment/Service/SA `demo-gateway-istio`. Annotate the Gateway with `networking.istio.io/service-type: NodePort` and set the listener's Service to NodePort 30080 via the kind mapping if straightforward; otherwise rely on port-forward only (verify.sh uses port-forward regardless).

### 60-secrets.yaml (generated)
Banner: `# DEMO ONLY: private key committed for reproducibility. Never do this in production.` Secret `portal-signing-key` (portal-ns) with `private.pem`, `public.pem`; ConfigMaps `portal-public-key` in `svc-a-ns` and `svc-b-ns` with `public.pem`.

### 90-test-pods.yaml
Three long-running `curlimages/curl` pods (`sleep infinity`): `curl` in `rogue-ns`, `curl` in `default`, `curl-as-svc-a` in `svc-a-ns` with `serviceAccountName: svc-a-sa`. Committed rather than `kubectl run --overrides` so verify.sh is deterministic and re-runnable; pods created after the namespace label are captured from their first packet (research 03 §8).

## 6. Scripts

All scripts start with this exact guard (copy verbatim; `setup-cluster.sh` uses only the first three lines and instead asserts `kind get clusters` does not already list `istio-demo`). It ignores whatever `KUBECONFIG`/current-context the developer has and can only ever talk to the kind cluster:

```bash
set -euo pipefail
KIND_CLUSTER=istio-demo
KCTX="--context kind-${KIND_CLUSTER}"
# Guard: the developer's kubeconfig may point at real clusters. Never run without the kind context.
kubectl $KCTX config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null | grep -qx "kind-${KIND_CLUSTER}" \
  || { echo "FATAL: kube context kind-${KIND_CLUSTER} not found; run scripts/setup-cluster.sh first" >&2; exit 1; }
kubectl() { command kubectl $KCTX "$@"; }   # every later kubectl call in this script is pinned
```

Also `JAVA_HOME=$(/usr/libexec/java_home -v 21)` wherever Maven runs.

- **gen-keys.sh**: `openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out keys/portal.key`; `openssl pkey -in keys/portal.key -pubout -out keys/portal.pub`; a second pair `keys/other.key` for the forged-token test; then the tested `pem-to-jwk` body from research 04 §1 (`openssl rsa -pubin -noout -modulus` → `xxd -r -p` → base64url; exponent from `-text`; `jq` to emit `{"keys":[...]}` with `kid: portal-key-1`), write `k8s/60-secrets.yaml` and patch the `jwks` in `k8s/32-request-authentication.yaml`. `keys/` is git-ignored except that `60-secrets.yaml` is committed for reproducibility.
- **mint-jwt.sh** `<private.pem> [ttl] [kid] [sub] [tenant]`: the tested body from research 04 §2 (`jq -cn` + `tr -d '\n'` + `printf '%s.%s' | openssl dgst -sha256 -sign -binary`). Never `echo` into `dgst`; `base64 | tr -d '\n=' | tr '+/' '-_'` (no `-w0`, macOS). Expired token uses **`-120`** because Envoy allows 60 s clock skew.
- **setup-cluster.sh**: from research 02's copy-paste block: `kind create cluster --name istio-demo --image "$KIND_NODE_IMAGE" --config scripts/kind-config.yaml`; assert `istioctl version --remote=false` is 1.31.0; install Gateway API v1.6.0 experimental server-side; `istioctl install $KCTX --set profile=ambient --skip-confirmation`; wait for istiod/ztunnel/istio-cni. No platform flag for kind.
- **build-and-load.sh**: `mvn -q -DskipTests package`; `docker build` three images; `kind load docker-image --name istio-demo`.
- **deploy.sh**: `kubectl $KCTX apply -f k8s/` in filename order (00 first), wait for waypoint and gateway Deployments, then all app pods Ready, then print `kubectl $KCTX get authorizationpolicies -A`.
- **verify.sh**: see §7. Uses `kubectl port-forward $KCTX -n istio-ingress svc/demo-gateway-istio 18080:80` in the background with a trap to kill it; cookie jar in a temp dir; login via `POST /login` (`username`, `password` form fields; CSRF off); tokens from `mint-jwt.sh`; in-cluster calls via `kubectl exec` into the pods from `90-test-pods.yaml` with `curl -s -o body -w '%{http_code}'`. Prints `PASS`/`FAIL` per scenario and exits non-zero if any fail.

## 7. verify.sh scenarios and exact expectations (research 03 §5, ticket 08)

| # | Client | Call | Expect |
|---|---|---|---|
| 1a | host via port-forward, logged in as alice | `GET /api/hello` | 200; `.downstream.downstream.sub=="alice"`, `.tenant_id=="tenant-001"` |
| 1b | same as bob | `GET /api/hello` | 200; `bob` / `tenant-002` |
| 2a | `curl` pod in `rogue-ns` (in mesh, wrong identity) | `GET http://service-a.svc-a-ns:8080/hello` | **403**, body `RBAC: access denied` (waypoint) |
| 2b | `curl` pod in `default` (not in mesh, plaintext) | same | **no HTTP response**; curl exit 56 or 52 (accept either), ztunnel L4 reset under STRICT |
| 3 | `curl-as-svc-a` in `svc-a-ns`, no token | `GET http://service-b.svc-b-ns:8080/hello` | **403** `RBAC: access denied` (not 401: missing token passes authn as anonymous, fails `requestPrincipals`) |
| 4a | same, valid token | `POST /hello` | **403** `RBAC: access denied` |
| 4b | same, valid token | `GET /other` | **403** `RBAC: access denied` |
| 5 | same, token with exp = now−120 s | `GET /hello` | **401**, body contains `Jwt is expired` |
| 6 | same, token signed with `other.key`, same kid | `GET /hello` | **401**, body contains `Jwt verification fails` |
| 7 (bonus) | same, valid token | `GET /hello` | 200; proves the svc-a-sa identity + JWT path works, isolating 3–6 |

Valid tokens for 4–7 come from `mint-jwt.sh keys/portal.key 300` (same claims as portal would mint).

## 8. README (English) must contain

1. ASCII diagram (adapt §2), marking the three ns, SA identities, mTLS segments, waypoints, gateway ns, rogue-ns/default test clients.
2. Hop-by-hop walk-through of one request from browser to service-b: what is checked at each hop and by whom (use the per-hop table).
3. Table: security properties provided by Istio vs. by application code (service identity, transport encryption, service-level authz, method/path authz, user authentication, user identity propagation, tenant claim, in-app claim access, Authorization Decision Point).
4. Troubleshooting, at least: missing ambient label; AuthorizationPolicy in the wrong namespace; L7 fields on a `selector` policy → fail-safe DENY; JWKS unreachable (istiod fetches `jwksUri`); CNI NetworkPolicy blocking (timeout, not 403); **waypoint SA not allowed at ztunnel** (client sees an upstream error from the waypoint instead of `RBAC: access denied`; destination ztunnel logs `connection closed due to policy rejection`); **`forwardOriginalToken` false → app 401 on happy path**; **`kid` mismatch → 401 `Jwks doesn't have key to match kid or alg from Jwt`**; **kind default node image 1.37 unsupported**.
5. JWKS production options and key rotation: (1) portal serves `/.well-known/jwks.json` and `portal-ns` allows istiod's SA (`cluster.local/ns/istio-system/sa/istiod`); (2) JWKS on a separate service outside deny-all; (3) external IdP. Rotation per option; for the inline option: add new key to `jwks`, re-apply, switch portal `kid`, remove old key after TTL.
6. Where the Authorization Decision Point lives and how OPA would plug in later.
7. Local run without Istio: `mvn spring-boot:run` per module with `./keys` paths, and how to hit `/hello` with a `mint-jwt.sh` token.

## 9. Implementation method

Use `superpowers:writing-plans` to turn this brief into a task-by-task plan, then `superpowers:executing-plans` (or `subagent-driven-development`) with checkpoints after: (1) Maven build green, (2) `setup-cluster.sh` complete, (3) `deploy.sh` all pods Ready, (4) `verify.sh` 10/10 PASS. Reason: ~40 files across three toolchains with a real cluster in the loop; checkpoints catch the policy-layout mistakes early. If `verify.sh` fails on 2a/3/4, check the waypoint L4 allows and `targetRefs` first (research 03 implications), not the Java.

## 10. Open items delegated to the implementer (routine)

- Exact NodePort/kind mapping for the browser demo if `networking.istio.io/service-type: NodePort` is awkward; port-forward is the required path.
- Whether `/healthz` needs `permitAll` on portal (yes) and whether kubelet probes traverse ztunnel (they do not; no policy needed).
- Curl exit code for 2b (56 vs 52) is unconfirmed: accept both and print which was observed.
