# Research: ambient AuthorizationPolicy / RequestAuthentication / PeerAuthentication semantics (Istio 1.31)

Resolves ticket `issues/03-research-ambient-authz-semantics.md`. Researched 2026-09-17 against istio.io (latest = 1.31 docs line), Istio 1.31 release notes, and `istio/istio` `release-1.31` source. Terms follow `CONTEXT.md` (Service Identity, Request Principal, Waypoint, Deny-All Baseline, Ingress Gateway).

Legend: **Confirmed** = quoted from a primary source. **Inferred** = follows from confirmed statements but no single doc sentence says it. **Unconfirmed** = could not be pinned to a primary source; verify on the kind cluster.

---

## 1. Namespace-wide empty-spec deny-all (`spec: {}`): which enforcement points apply it?

**Confirmed: ztunnel applies it to every captured workload in the namespace.**

- L4 policies "are scoped by the namespace in which the policy object resides, and an optional `selector` in the `spec`." An empty spec has no selector, so it selects every workload in the namespace. "The enforcement point is the receiving (server-side) ztunnel proxy in the path of a connection." "Once a policy is provisioned, pods targeted by the policy only permit traffic which is explicitly allowed."
  https://istio.io/latest/docs/ambient/usage/l4-policy/
- Reference: "The selector will match with workloads in the same namespace as the authorization policy. If the authorization policy is in the root namespace, the selector will additionally match with workloads in all namespaces." An `ALLOW` policy with no rules is the documented "allow-nothing" pattern (default action is ALLOW; no rule matches; everything is denied).
  https://istio.io/latest/docs/reference/config/security/authorization-policy/

**Confirmed: the Waypoint does NOT apply it.** A policy with no `targetRefs` is never attached to a waypoint, regardless of selector.

- Reference doc, `targetRefs` field: "Waypoint proxies are required to use this field for policies to apply; `selector` policies will be ignored."
  https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Source, `pilot/pkg/model/policyattachment.go` (`WorkloadPolicyMatcher.ShouldAttachPolicy`, release-1.31):
  ```go
  // gateway with no targetRefs: (sometimes) fallback to selector
  if len(targetRefs) == 0 {
      // gateways require the feature flag for selector-based policy
      // waypoints never use selector
      if p.IsWaypoint || !features.EnableSelectorBasedK8sGatewayPolicy {
          log.Debugf("Ignoring workload-scoped %s/%s %s for gateway %s.%s because it has no targetRef", ...)
          return false
      }
      return p.isSelected(policy)
  }
  ```
  https://raw.githubusercontent.com/istio/istio/release-1.31/pilot/pkg/model/policyattachment.go
- The waypoint pod is also not captured by ztunnel, so the deny-all is not enforced *in front of* the waypoint either: the waypoint pod template carries labels `istio.io/dataplane-mode: none` and `sidecar.istio.io/inject: "false"`.
  https://raw.githubusercontent.com/istio/istio/release-1.31/manifests/charts/istio-control/istio-discovery/files/waypoint.yaml
- Corollary (Inferred): with only a namespace deny-all, the Waypoint's own inbound accepts any in-mesh mTLS client; the *only* thing that restricts who may talk *through* the Waypoint is a policy attached with `targetRefs` (Service or Gateway). Conversely, the application pods behind the Waypoint are protected by ztunnel regardless.
- Note: 1.31 has two opt-in istiod flags that change this picture, both default `false`: `ENABLE_LAYERED_WAYPOINT_AUTHORIZATION_POLICIES` ("If enabled, selector based authorization policies will be enforced as L4 policies in front of the waypoint") and `PILOT_AUTO_ALLOW_WAYPOINT_POLICY` ("If enabled, zTunnel will receive synthetic authorization policies for each workload ALLOW the Waypoint's identity"). The demo should not rely on either; they are off in a default `profile=ambient` install.
  https://istio.io/latest/docs/reference/commands/pilot-discovery/

---

## 2. Waypoint -> workload hop: whose identity does the destination ztunnel see?

**Confirmed: the Waypoint's own ServiceAccount, not the original caller's.**

- "With only the secure overlay, traffic appears at the destination ztunnel with the identity of the _source_ workload." ... "Waypoint proxies do not impersonate the identity of the source workload. Once you have introduced a waypoint to the traffic path, the destination ztunnel will see traffic with the _waypoint's_ identity, not the source identity." ... "if you are dependent on the source identity, you should attach your policy to your waypoint proxy. A second policy may be targeted at your workload to make its ztunnel enforce policies like 'in-mesh traffic must come from my waypoint.'"
  https://istio.io/latest/docs/ambient/usage/l4-policy/
- "A waypoint uses the service account named after its `Gateway`." and "If enforcing a waypoint's Layer 7 policies is a security requirement, make the waypoint mandatory with an `AuthorizationPolicy` that allows only the waypoint's identity." ... "a policy on the destination workloads that allows only that identity denies any client that reaches them without first passing through the waypoint."
  https://istio.io/latest/docs/ambient/usage/waypoint/
- Waypoint template: `ServiceAccount.metadata.name: {{.ServiceAccount | quote}}`; the proxy's `ISTIO_META_SERVICE_ACCOUNT` / `SERVICE_ACCOUNT` env come from `spec.serviceAccountName`. With `istioctl waypoint apply` (default Gateway name `waypoint`) the principal is therefore `cluster.local/ns/<ns>/sa/waypoint`.
  https://raw.githubusercontent.com/istio/istio/release-1.31/manifests/charts/istio-control/istio-discovery/files/waypoint.yaml
- Migration guide example principal for exactly this purpose: `"cluster.local/ns/bookinfo/sa/waypoint"`.
  https://istio.io/latest/docs/ambient/migrate/migrate-policies/

**Confirmed: there is no special-casing of "traffic from my own waypoint" in ztunnel** (default flags). `PILOT_AUTO_ALLOW_WAYPOINT_POLICY` (default `false`) exists precisely because ztunnel does not do this on its own.
  https://istio.io/latest/docs/reference/commands/pilot-discovery/

**Consequence for the spec (Inferred from the above):** the Deny-All Baseline in `svc-a-ns` and `svc-b-ns` blocks the Waypoint -> pod hop. Each of those namespaces needs an L4 `ALLOW` enforced by ztunnel (no `targetRefs`; `selector` on the app or none) whose `principals` is `cluster.local/ns/<ns>/sa/waypoint`. Because ztunnel then only sees the Waypoint's identity, the `principals: [portal-sa]` / `principals: [svc-a-sa]` checks in the spec's `allow-portal-to-a` / `allow-a-to-b` are only meaningful on the Waypoint (`targetRefs`) and would *fail* if placed in a ztunnel-enforced policy. The getting-started guide confirms the same two-tier arrangement: "Both the gateway and waypoint service accounts must be authorized at the ztunnel level to establish connections."
  https://istio.io/latest/docs/ambient/getting-started/enforce-auth-policies/

---

## 3. L7 policy binding: `targetRefs` Service vs Gateway; fail-safe DENY

**Confirmed: both kinds work on a Waypoint in 1.31; `Service` is the recommended binding for per-service method/path/`requestPrincipals` rules.**

- Reference `targetRefs` supported kinds: `kind: Gateway` (`gateway.networking.k8s.io`, same namespace), `kind: GatewayClass` (root namespace), `kind: Service` (group `""`, same namespace, "waypoints only"), `kind: ServiceEntry` (`networking.istio.io`).
  https://istio.io/latest/docs/reference/config/security/authorization-policy/
- "Targeting a `Service` is the more precise option and is recommended when the policy should apply to a single service." "Targeting the `Gateway` is useful when the policy should apply to all services in the namespace."
  https://istio.io/latest/docs/ambient/migrate/migrate-policies/
- Getting-started L7 example uses `targetRefs: [{kind: Service, group: "", name: productpage}]` with `principals` + `methods: ["GET"]`.
  https://istio.io/latest/docs/ambient/getting-started/enforce-auth-policies/
- Source: a Service-attached policy matches when the waypoint serves that Service (`p.IsWaypoint && matchesGroupKind(targetRef, gvk.Service)` and the Service is in the policy's namespace, registry Kubernetes).
  https://raw.githubusercontent.com/istio/istio/release-1.31/pilot/pkg/model/policyattachment.go

**Confirmed: an L7 field in a `selector`-bound (ztunnel-enforced) policy becomes DENY.**

- Exact sentence: "The ztunnel cannot enforce L7 policies. If a policy with rules matching L7 attributes (i.e. those not listed in the table above) is targeted such that it will be enforced by a receiving ztunnel, it will fail safe by becoming a `DENY` policy." Worked example output: "Even if the identity of the client pod is correct, the presence of a L7 attribute causes the ztunnel to deny the connection: `command terminated with exit code 56`".
  https://istio.io/latest/docs/ambient/usage/l4-policy/
- Same statement, L7 page: "If a policy with rules matching L7 attributes is targeted with a workload selector (rather than attached with a `targetRef`), such that it is enforced by a ztunnel, it will fail safe by becoming a `DENY` policy."
  https://istio.io/latest/docs/ambient/usage/l7-features/
- Migration guide: "Any `AuthorizationPolicy` using a workload `selector` with L7 rules (HTTP methods, paths, or headers) that remains active after sidecars are removed will be picked up by ztunnel, which cannot enforce L7 rules and will convert it into a `DENY` policy for all traffic to that workload."
  https://istio.io/latest/docs/ambient/migrate/migrate-policies/
- Note: `requestPrincipals` is an L7 attribute (derived from JWT, which only the Waypoint's Envoy validates), so the same fail-safe applies to it.

---

## 4. RequestAuthentication binding, inline `jwks`, `kid`/`alg`, no-token behaviour

**Confirmed: `targetRefs` -> `kind: Service` is supported (waypoints only); `Gateway` also works; `selector` is ignored by waypoints.**

- Reference `targetRefs` kinds: `Gateway` (same namespace), `GatewayClass` (root namespace), `Service` (group `""`, same namespace, "waypoints only"), `ServiceEntry`. "Waypoint proxies are required to use this field for policies to apply; `selector` policies will be ignored."
  https://istio.io/latest/docs/reference/config/security/request_authentication/
- Migration guide: "`RequestAuthentication` and `WasmPlugin` resources require a waypoint proxy and must be targeted using `targetRefs` to point at the waypoint."
  https://istio.io/latest/docs/ambient/migrate/migrate-policies/
- Source: the same `ShouldAttachPolicy` matcher is used for RequestAuthentication; a Service-attached policy applies when the waypoint serves that Service.
  https://raw.githubusercontent.com/istio/istio/release-1.31/pilot/pkg/model/policyattachment.go
- Recommendation (Inferred): bind to `Service` (one RequestAuthentication per enrolled Service, same namespace) so the JWT rule and the `requestPrincipals` policy attach to the same object; binding to the `Gateway` `waypoint` also works and covers every Service in the namespace.

**Confirmed: inline `jwks` is supported; `jwksUri` is not needed.**

- `jwks`: "JSON Web Key Set of public keys to validate signature of the JWT." Only one of `jwksUri` / `jwks` should be set.
  https://istio.io/latest/docs/reference/config/security/request_authentication/
- Source: inline keys become an Envoy `local_jwks` via `push.JwtKeyResolver.BuildLocalJwks(jwtRule.JwksUri, jwtRule.Issuer, jwtRule.Jwks, ...)`; `issuer`, `audiences`, `forwardOriginalToken` map 1:1 to the Envoy provider.
  https://raw.githubusercontent.com/istio/istio/release-1.31/pilot/pkg/security/authn/policy_applier.go

**Confirmed: `kid` / `alg` matching rules (Envoy's `jwt_authn` uses google/jwt_verify_lib).**

- Key selection: `if (!jwt.kid_.empty() && !jwk->kid_.empty() && jwk->kid_ != jwt.kid_) continue;` and `if (!jwk->alg_.empty() && jwk->alg_ != jwt.alg_) continue;` then `kty` must match. No matching key -> `JwksKidAlgMismatch`; matching key but bad signature -> `JwtVerificationFail`.
  https://raw.githubusercontent.com/google/jwt_verify_lib/master/src/verify.cc
- Practical rule for the demo: the JWK needs `kty: RSA`, `n`, `e`; `kid` is optional but if both JWT header and JWK carry it they must be equal; `alg` in the JWK is optional, and if present must be `RS256`. Put `"kid":"portal-key-1","alg":"RS256","use":"sig"` in the JWK and set the same `kid` in the Nimbus header.
- Required JWK fields for RSA (error strings): "[n] field is missing for a RSA key", "[e] field is missing for a RSA key", "[kty] is missing in [keys]".
  https://raw.githubusercontent.com/google/jwt_verify_lib/master/src/status.cc

**Confirmed: no token -> request passes RequestAuthentication unauthenticated, then the `requestPrincipals` ALLOW rule fails -> 403 `RBAC: access denied` (not 401).**

- Reference: "A request that does not contain any authentication credentials will be accepted but will not have any authenticated identity." Enforce with an AuthorizationPolicy using `requestPrincipals: ["*"]` (or a specific principal).
  https://istio.io/latest/docs/reference/config/security/request_authentication/
- Source comment in `policy_applier.go`: "the filter should reject all requests with invalid token. On the other hand, if no token provided, the request is allowed." Implemented as `requires_any: [{provider_name: ...}, {allow_missing: {}}]`.
  https://raw.githubusercontent.com/istio/istio/release-1.31/pilot/pkg/security/authn/policy_applier.go
- Task doc: no token -> 200 before any AuthorizationPolicy; invalid token -> 401; after adding the `requestPrincipals` policy, a request without a token gets 403.
  https://istio.io/latest/docs/tasks/security/authentication/authn-policy/#end-user-authentication
- Envoy RBAC filter denial: `sendLocalReply(Http::Code::Forbidden, "RBAC: access denied", ...)`.
  https://raw.githubusercontent.com/envoyproxy/envoy/main/source/extensions/filters/http/rbac/rbac_filter.cc

**Confirmed: invalid token -> 401 with a plain-text body naming the failure; audience mismatch is the one 403 case.**

- Envoy `jwt_authn` `onComplete`: status `Forbidden` when `status == Status::JwtAudienceNotAllowed`, otherwise `Unauthorized`; body is `getStatusString(status)`; header `WWW-Authenticate: Bearer realm="...", error="invalid_token"`.
  https://raw.githubusercontent.com/envoyproxy/envoy/main/source/extensions/filters/http/jwt_authn/filter.cc
- Status strings relevant to verify.sh: `Jwt is expired`, `Jwt verification fails`, `Jwks doesn't have key to match kid or alg from Jwt`, `Jwt issuer is not configured`, `Audiences in Jwt are not allowed`, `Jwt is missing`.
  https://raw.githubusercontent.com/google/jwt_verify_lib/master/src/status.cc

**Confirmed and important for Layer 2 of the spec: the waypoint strips the token unless `forwardOriginalToken: true`.**

- `forwardOriginalToken`: "If set to true, the original token will be kept for the upstream request. Default is false."
  https://istio.io/latest/docs/reference/config/security/request_authentication/
- The spec's service-a / service-b run `spring-boot-starter-oauth2-resource-server` and read claims in-app, so every RequestAuthentication in the demo must set `forwardOriginalToken: true`, otherwise the app sees no `Authorization` header and returns 401 on the happy path.

---

## 5. `requestPrincipals` format, denial responses, and what the client sees in scenario 2

**Confirmed: format `<ISS>/<SUB>`; `*` = any authenticated request principal.**

- "A list of request identities derived from the JWT. The request identity is in the format of `"<ISS>/<SUB>"`" ... "If not set, any request principal is allowed." The task doc uses `requestPrincipals: ["testing@secure.istio.io/testing@secure.istio.io"]` and `notRequestPrincipals: ["*"]` for "no valid token".
  https://istio.io/latest/docs/reference/config/security/authorization-policy/
  https://istio.io/latest/docs/tasks/security/authentication/authn-policy/#end-user-authentication
- For the demo's claims (`iss: https://portal.internal`, `sub: alice`) the Request Principal is `https://portal.internal/alice`; use `requestPrincipals: ["https://portal.internal/*"]` to accept any user minted by the Portal.

**Confirmed: Waypoint (Envoy) denial = HTTP 403, body `RBAC: access denied`.**

- Envoy RBAC filter source (above) and the ambient getting-started output: `curl ... -X DELETE` -> `RBAC: access denied`.
  https://istio.io/latest/docs/ambient/getting-started/enforce-auth-policies/

**Confirmed: ztunnel (L4) denial = no HTTP response; the TCP connection is closed. `curl` exits 56.**

- Docs: an L4-denied `kubectl exec deploy/curl -- curl -s http://productpage:9080/productpage` prints `command terminated with exit code 56`.
  https://istio.io/latest/docs/ambient/usage/l4-policy/
  https://istio.io/latest/docs/ambient/getting-started/enforce-auth-policies/
- Mechanism (source): destination ztunnel answers the HBONE CONNECT with `StatusCode::UNAUTHORIZED` and flag `AuthorizationPolicyDenied`; the source ztunnel's H2 client turns any non-200 CONNECT into `Error::HttpStatus` and the client's TCP connection is dropped. Error strings logged by ztunnel: "connection closed due to policy rejection: allow policies exist, but none allowed" / "explicitly denied by: <ns>/<policy>".
  https://raw.githubusercontent.com/istio/ztunnel/master/src/proxy/inbound.rs
  https://raw.githubusercontent.com/istio/ztunnel/master/src/proxy/h2/client.rs
  https://raw.githubusercontent.com/istio/ztunnel/master/src/proxy.rs
- Plaintext (non-HBONE) inbound is also RBAC-checked by ztunnel (`assert_rbac` in `inbound_passthrough.rs`); a plaintext connection has `src_identity == None`, so once any ALLOW policy exists it can never match a `principals` rule and is closed without a response.
  https://raw.githubusercontent.com/istio/ztunnel/master/src/proxy/inbound_passthrough.rs
  https://raw.githubusercontent.com/istio/ztunnel/master/src/state.rs

**Scenario 2 (curl pod in `default` -> `service-a.svc-a-ns:8080/hello`): which hop denies depends on whether the client pod is in the ambient mesh.**

- Confirmed: only in-mesh clients are routed through the destination's Waypoint. "After a namespace is enrolled to use a waypoint, any requests from any pods using the ambient data plane mode, to any service running in that namespace, will be routed through the waypoint". Source: the outbound path returns early to the waypoint whenever `fetch_service_waypoint` finds one for the target Service.
  https://istio.io/latest/docs/ambient/usage/waypoint/
  https://raw.githubusercontent.com/istio/ztunnel/master/src/proxy/outbound.rs
- Case A, `default` labelled `istio.io/dataplane-mode=ambient`: client ztunnel -> `svc-a-ns` Waypoint (HBONE, source identity `cluster.local/ns/default/sa/default`) -> the Service-attached ALLOW policy (`principals: portal-sa`) does not match -> **403 `RBAC: access denied`** from the Waypoint. The client never reaches service-a's ztunnel. This is the only configuration in which the spec's expected string appears.
- Case B, `default` not in the mesh: plaintext to the ClusterIP -> kube-proxy -> service-a pod -> ztunnel inbound passthrough -> denied (STRICT and/or Deny-All Baseline: no identity) -> connection closed, **no HTTP body**; curl exits non-zero (56 "Recv failure" or 52 "Empty reply" - exact code Unconfirmed). Asserting on `RBAC: access denied` would FAIL here.
- Recommendation: verify.sh must run scenario 2 from an ambient-enrolled namespace (label `default`, or create a `test-ns` with the ambient label and no waypoint) and assert `HTTP 403` + body `RBAC: access denied`; optionally add a scenario 2b from a non-mesh namespace asserting a TCP-level failure (non-zero curl exit, no body) to demonstrate the L4 layer.

---

## 6. PeerAuthentication STRICT in ambient

**Confirmed: supported and enforced by ztunnel; `DISABLE` is ignored; default is PERMISSIVE.**

- "Istio's peer authentication policies, which configure mutual TLS (mTLS) modes, are supported by ztunnel." "The default policy for ambient mode is `PERMISSIVE`, which allows pods to accept both mTLS-encrypted traffic (from within the mesh) and plain text traffic (from without)." "it is not possible to use the `DISABLE` mode in a policy. Such policies will be ignored."
  https://istio.io/latest/docs/ambient/usage/l4-policy/
- Reference: STRICT = "Connection is an mTLS tunnel (TLS with client cert must be presented)."; in ambient "DISABLE mode is not supported".
  https://istio.io/latest/docs/reference/config/security/peer_authentication/

**Confirmed: a namespace-scoped policy (no selector, non-root namespace) is sufficient; mesh-wide is not required.**

- Reference scoping: root-namespace policy = mesh-wide; "Policies in non-root namespaces apply to all workloads in that namespace by default"; a workload selector narrows further. Task doc: "namespace-wide peer authentication policy" applies to "all workloads within a particular namespace".
  https://istio.io/latest/docs/reference/config/security/peer_authentication/
  https://istio.io/latest/docs/tasks/security/authentication/authn-policy/
- Mechanism: istiod "computes the effective policy for that workload (taking into account the mesh-wide -> namespace -> workload precedence rules)" and converts STRICT into a synthetic ztunnel `Authorization` of action DENY matching unauthenticated sources (`notPrincipals` presence match), so "unauthenticated traffic will be rejected before it reaches the Waypoint proxy".
  https://raw.githubusercontent.com/istio/istio/master/architecture/ambient/peer-authentication.md
- History: 1.25 fixed ambient PeerAuthentication being "overly strict" and a bug with multiple STRICT port-level rules (issue #53884 / PR #54073, 1.24.0). Irrelevant on 1.31 but worth a README footnote if someone pins 1.24.
  https://istio.io/latest/news/releases/1.25.x/announcing-1.25/change-notes/
  https://github.com/istio/istio/issues/53884
- Note (Inferred): with the Deny-All Baseline already present, STRICT adds little at ztunnel (plaintext has no identity and cannot match any ALLOW), but it is the documented way to state the intent and it also covers namespaces/ports with no AuthorizationPolicy. Keep it, one per application namespace, `mtls.mode: STRICT`, no selector.

---

## 7. Ingress Gateway -> Portal: identity and whether a deny-all in the gateway's namespace would hit the gateway

**Confirmed: the gateway reaches ambient workloads over HBONE with its own ServiceAccount identity; `portal-ns` ztunnel sees `cluster.local/ns/<gw-ns>/sa/<gateway-name>-istio`.**

- The ambient getting-started L4 policy on `productpage` (ztunnel-enforced, `selector`) allows exactly `cluster.local/ns/default/sa/bookinfo-gateway-istio`, "which is the service account that is used by the Bookinfo gateway", and the browser path keeps working - direct evidence that the destination ztunnel authenticates the gateway by its own SA.
  https://istio.io/latest/docs/ambient/getting-started/enforce-auth-policies/
- Generated resource naming: "each `Gateway` will automatically provision a `Service` and `Deployment`. These will be named `<Gateway name>-<GatewayClass name>`" (waypoint class excepted). The kube-gateway template creates a ServiceAccount named `{{.ServiceAccount}}` and sets `spec.serviceAccountName` to it; the getting-started principal shows that value is `<Gateway name>-istio`.
  https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/#automated-deployment
  https://raw.githubusercontent.com/istio/istio/release-1.31/manifests/charts/istio-control/istio-discovery/files/kube-gateway.yaml
- "An ingress gateway may run in a non-ambient namespace, and expose services provided by ambient mode, sidecar mode or non-mesh pods."
  https://istio.io/latest/docs/ambient/usage/add-workloads/
- The gateway pod is not ztunnel-captured: Istio-shipped gateways carry ambient exclusion labels since 1.25 and maintainers confirm `istio.io/dataplane-mode=none` on gateway pods "is expected". The gateway's own Envoy speaks HBONE.
  https://istio.io/latest/news/releases/1.25.x/announcing-1.25/change-notes/
  https://github.com/istio/istio/discussions/57801
- For the spec (ADR-0002 layout): `allow-gw-to-portal` in `portal-ns` must allow `cluster.local/ns/istio-ingress/sa/<gateway-name>-istio` (e.g. Gateway `demo-gateway` -> `demo-gateway-istio`). `portal-ns` has no Waypoint, so this is a ztunnel-enforced L4 policy and the gateway identity is what ztunnel sees.

**Confirmed: ADR-0002's premise holds - a namespace-wide, selector-less AuthorizationPolicy in the gateway's namespace IS enforced by the Gateway API gateway's Envoy (default istiod flags).**

- Source: for a Gateway API workload with no `targetRefs`, `ShouldAttachPolicy` falls back to selector matching unless `IsWaypoint` or `EnableSelectorBasedK8sGatewayPolicy` is false; `isSelected` returns true for a nil selector.
  https://raw.githubusercontent.com/istio/istio/release-1.31/pilot/pkg/model/policyattachment.go
- Flag reference: `ENABLE_SELECTOR_BASED_K8S_GATEWAY_POLICY`, default `true`: "If disabled, Gateway API gateways will ignore workloadSelector policies, only applying policies that select the gateway with a targetRef."
  https://istio.io/latest/docs/reference/commands/pilot-discovery/
- Maintainer (howardjohn) on a selector-bound policy hitting an ingress gateway in ambient 1.24: "it is applied to an ingressgateway -- so its fine."
  https://github.com/istio/istio/discussions/54440
- Consequence: a Gateway in `portal-ns` would be subject to the `portal-ns` Deny-All Baseline and would reject browser traffic (which has no mTLS peer identity) - exactly the ADR's reasoning. Keeping the Gateway in `istio-ingress` with no deny-all is the correct choice. If the team wanted to harden the gateway namespace later, the right tool is a policy with `targetRefs: kind: Gateway` (L7 rules allowed there), not a selector-less deny-all.

**Caveat for the README:** ingress traffic bypasses destination Waypoints by default ("By default, ingress-originated traffic will not use the destination service waypoint, even when `istio.io/use-waypoint` is set"); opt in per Service with `istio.io/ingress-use-waypoint=true` (needs `ENABLE_INGRESS_WAYPOINT_ROUTING=true` on istiod). Not needed for the spec because `portal-ns` has no Waypoint, but it is the reason a "waypoint in portal-ns" variant would silently skip L7 policy for browser traffic.
  https://istio.io/latest/docs/ambient/usage/waypoint/

---

## 8. Ad-hoc test pods (`kubectl run`) in an ambient namespace

**Confirmed: a pod created in an already-labelled namespace is captured before its containers start; a pod that predates the label is captured in place without restart.**

- "The CNI plugin is executed synchronously during the creation of the Pod sandbox by the container runtime, before processes or containers are run within the Pod." It programs redirection and hands ztunnel the pod's netns; "Only once those two conditions are met does the CNI plugin return success - effectively allowing our plugin to block Pod scheduling until we are ready." "An alternative flow is when a pod is enrolled into ambient mode after it starts up. In this case, the CNI Agent is watching for Pod events from the API server directly and performing the same setup." Lazy loading: "Ztunnel will accept all connections, but it will not start forwarding traffic until all the above is fetched."
  https://raw.githubusercontent.com/istio/istio/master/architecture/ambient/ztunnel-cni-lifecycle.md
- "The `istio-cni` node agent responds to CNI events such as pod creation and deletion, and also watches the underlying Kubernetes API server for events such as the ambient label being added to a pod or namespace."
  https://istio.io/latest/docs/ambient/architecture/traffic-redirection/
- "Unlike the sidecar data plane mode, there is no need to restart applications to add them to the mesh."
  https://istio.io/latest/docs/ambient/usage/add-workloads/
- Capture conditions: namespace or pod has `istio.io/dataplane-mode=ambient`, pod lacks `istio.io/dataplane-mode=none`, pod lacks `sidecar.istio.io/status`; namespaces in `cni.values.excludeNamespaces` are skipped.
  https://istio.io/latest/docs/ambient/usage/add-workloads/#pod-selection-logic-for-ambient-and-sidecar-modes
- Verification: pod annotation `ambient.istio.io/redirection: enabled` ("This indicates `istio-cni` enabled redirection") and `istioctl ztunnel-config workload` showing `PROTOCOL HBONE`. (Wiki is istio-owned but not the versioned docs; treat as Confirmed-by-maintainers.)
  https://github.com/istio/istio/wiki/Troubleshooting-Istio-Ambient
  https://istio.io/latest/docs/ambient/usage/troubleshoot-ztunnel/

**Caveats for verify.sh:**

- Identity: `kubectl run` uses the namespace's `default` ServiceAccount. Scenario 3 ("pod in `svc-a-ns` running as `svc-a-sa`") needs `kubectl run ... --overrides='{"spec":{"serviceAccountName":"svc-a-sa"}}'` (or a committed test Pod manifest). Ambient identity is the pod's SA, nothing else. (Inferred from the SPIFFE format `cluster.local/ns/<ns>/sa/<sa>`.)
- Scenario 2's client namespace must itself be ambient-labelled for the request to traverse the Waypoint (see 5). `default` is not labelled by `istioctl install`; either label it in `setup-cluster.sh` or use a dedicated `test-ns`.
- Inbound-only: AuthorizationPolicy governs traffic *into* a workload, so the Deny-All Baseline in `svc-a-ns` does not stop the test pod's *outbound* calls. No extra allow is needed for the test pod. (Confirmed by "The enforcement point is the receiving (server-side) ztunnel proxy".)
  https://istio.io/latest/docs/ambient/usage/l4-policy/
- `hostNetwork` pods: istio-cni filters them (1.31 change notes list a fix for hostNetwork pod filtering); treat capture of hostNetwork pods as unsupported (Unconfirmed in the versioned docs) and do not use `--overrides` with `hostNetwork: true`.
  https://istio.io/latest/news/releases/1.31.x/announcing-1.31/change-notes/
- Use `kubectl run --rm -it --restart=Never --image=curlimages/curl` and wait for `Running`; the first connection may see a small latency while ztunnel fetches the workload (lazy loading above) but will not be refused.

---

## Release-note sweep 1.24 -> 1.31 (behaviour changes that touch this demo)

- 1.25: AuthorizationPolicy may bind to `GatewayClass istio-waypoint` (root namespace) for waypoint-wide defaults; ambient PeerAuthentication fixes ("overly strict", port-level STRICT); RequestAuthentication cross-namespace waypoint fix; namespace-level `istio.io/ingress-use-waypoint`; Istio-shipped gateways get ambient exclusion labels.
  https://istio.io/latest/news/releases/1.25.x/announcing-1.25/change-notes/
- 1.29: experimental AuthorizationPolicy dry-run in ztunnel; JWKS URI CIDR blocking.
  https://istio.io/latest/news/releases/1.29.x/announcing-1.29/change-notes/
- 1.30: waypoint can synthesize XFCC with the client identity via annotation `ambient.istio.io/xfcc-include-client-identity`; fix for regex metacharacter escaping in `source.principals` / `source.namespaces`.
  https://istio.io/latest/news/releases/1.30.x/announcing-1.30/change-notes/
- 1.31: `trustDomains` / `notTrustDomains` added to AuthorizationPolicy `Source`; `istio-agentgateway-waypoint` GatewayClass (not used here); no changes to ztunnel/waypoint policy attachment semantics.
  https://istio.io/latest/news/releases/1.31.x/announcing-1.31/change-notes/
  https://istio.io/latest/news/releases/1.31.x/announcing-1.31/upgrade-notes/
- 1.26-1.28: nothing affecting AuthorizationPolicy / RequestAuthentication / PeerAuthentication semantics in ambient.
  https://istio.io/latest/news/releases/1.26.x/announcing-1.26/change-notes/
  https://istio.io/latest/news/releases/1.27.x/announcing-1.27/change-notes/
  https://istio.io/latest/news/releases/1.28.x/announcing-1.28/change-notes/

---

## Implications for the spec's `k8s/3x-*.yaml` layout

Per-hop identities (what each enforcement point sees):

| Hop | Enforcer | Source principal seen | Policy binding that works |
|---|---|---|---|
| Ingress Gateway -> portal pod | `portal-ns` ztunnel | `cluster.local/ns/istio-ingress/sa/<gw>-istio` | L4, `selector`/none |
| portal pod -> `svc-a-ns` Waypoint | Waypoint (Envoy) | `cluster.local/ns/portal-ns/sa/portal-sa` + JWT | L7, `targetRefs: Service service-a` |
| `svc-a-ns` Waypoint -> service-a pod | `svc-a-ns` ztunnel | `cluster.local/ns/svc-a-ns/sa/waypoint` | L4, `selector`/none |
| service-a pod -> `svc-b-ns` Waypoint | Waypoint (Envoy) | `cluster.local/ns/svc-a-ns/sa/svc-a-sa` + JWT | L7, `targetRefs: Service service-b` |
| `svc-b-ns` Waypoint -> service-b pod | `svc-b-ns` ztunnel | `cluster.local/ns/svc-b-ns/sa/waypoint` | L4, `selector`/none |

Concrete corrections:

1. **`30-deny-all.yaml` - correct as specified, but document its reach.** The empty-spec policy in each namespace is enforced only by ztunnel on captured pods. It is *not* applied to the Waypoint (no `targetRefs`), and the Waypoint pod is not captured (`istio.io/dataplane-mode: none`). Add, per waypoint namespace, a waypoint-scoped allow-nothing: `AuthorizationPolicy` with `targetRefs: [{group: gateway.networking.k8s.io, kind: Gateway, name: waypoint}]` and empty rules. This keeps the spec's "no mesh-wide policy in istio-system" rule (the documented alternative binds to `GatewayClass istio-waypoint` and must live in the root namespace) while ensuring a future Service enrolled to the Waypoint without its own ALLOW policy is denied rather than allowed.
2. **`31-authorization-policies.yaml` is missing two L4 policies**, and spec item 8's condition is wrong: the Deny-All Baseline *is* a workload-level L4 policy, so the Waypoint's identity must be allowed unconditionally, in **both** waypoint namespaces:
   - `allow-waypoint-to-a` in `svc-a-ns`: `selector: {app: service-a}` (or none), `rules[].from.source.principals: ["cluster.local/ns/svc-a-ns/sa/waypoint"]`. No L7 fields, no `targetRefs`.
   - `allow-waypoint-to-b` in `svc-b-ns`: same with `cluster.local/ns/svc-b-ns/sa/waypoint`.
   Do **not** also list `portal-sa` / `svc-a-sa` in these L4 policies: ztunnel never sees those identities once the Waypoint is in the path, and leaving them out is what makes the Waypoint mandatory ("in-mesh traffic must come from my waypoint").
3. **`allow-portal-to-a` must be Waypoint-attached, not ztunnel-targeted.** The spec only says `allow-a-to-b` uses `targetRefs`; `allow-portal-to-a` must too (`targetRefs: [{group: "", kind: Service, name: service-a}]`), because (a) its `principals: portal-sa` check can only be satisfied at the Waypoint, and (b) spec item 5 requires `requestPrincipals` on it, which is an L7 attribute and would turn a `selector` policy into a ztunnel DENY. Recommended rules: `principals: ["cluster.local/ns/portal-ns/sa/portal-sa"]`, `requestPrincipals: ["https://portal.internal/*"]`, `to.operation.methods: ["GET"]`, `paths: ["/hello"]` (or whatever service-a exposes).
4. **`allow-a-to-b`**: as specified, plus `requestPrincipals: ["https://portal.internal/*"]`; `targetRefs` kind `Service` name `service-b`, group `""`.
5. **`32-request-authentication.yaml`**: one per waypoint namespace, `targetRefs: [{group: "", kind: Service, name: service-a|service-b}]`, `jwtRules[0]`: `issuer: https://portal.internal`, `audiences: ["internal-services"]`, inline `jwks` with `{"kty":"RSA","kid":"portal-key-1","alg":"RS256","use":"sig","n":"...","e":"AQAB"}`, and **`forwardOriginalToken: true`** (missing from the spec; without it the in-app resource server never sees the token). Portal must set the same `kid` in the JWT header.
6. **`20-peer-authentication.yaml`**: one `PeerAuthentication` per application namespace, `mtls.mode: STRICT`, no selector. Correct as specified; mesh-wide not needed; `DISABLE` would be ignored.
7. **`40-waypoints.yaml`**: `Gateway` named `waypoint`, `gatewayClassName: istio-waypoint`, listener `port: 15008, protocol: HBONE`, in `svc-a-ns` and `svc-b-ns`; label both namespaces `istio.io/use-waypoint: waypoint` (this is what `--enroll-namespace` does). The waypoint SA is therefore `waypoint`; the L4 principals above depend on this name.
8. **`50-gateway.yaml` / `allow-gw-to-portal`**: ADR-0002 confirmed. Principal is `cluster.local/ns/istio-ingress/sa/<Gateway name>-istio`; commit the Gateway name so the policy can be written statically. Optionally add `istio.io/dataplane-mode: none` on the gateway namespace to make the non-capture explicit (Istio already labels the pods).
9. **`00-namespaces.yaml` / `setup-cluster.sh`**: add an ambient-labelled test namespace (or label `default`) so scenario 2 traverses the Waypoint.
10. **verify.sh expected results** (assert status *and* body):

   | Scenario | Path | Denying hop | Expect |
   |---|---|---|---|
   | 1 happy path | browser -> gw -> portal -> a -> b | none | 200, body echoes `alice` / `tenant-001` |
   | 2 wrong Service Identity (in-mesh test ns) | test pod -> `svc-a-ns` Waypoint | Waypoint | **403** `RBAC: access denied` |
   | 2b (optional) non-mesh client | plaintext -> service-a ztunnel | ztunnel | curl non-zero exit (56/52), no body |
   | 3 right identity, no JWT | svc-a-sa pod -> `svc-b-ns` Waypoint | Waypoint (RBAC, not JWT filter) | **403** `RBAC: access denied` (not 401) |
   | 4 valid JWT, `POST /hello` or `GET /other` | -> `svc-b-ns` Waypoint | Waypoint RBAC | **403** `RBAC: access denied` |
   | 5 expired JWT | -> Waypoint JWT filter | Waypoint | **401** `Jwt is expired` |
   | 6 forged key, same `kid` | -> Waypoint JWT filter | Waypoint | **401** `Jwt verification fails` |
   | 6' forged key, other `kid` | -> Waypoint JWT filter | Waypoint | **401** `Jwks doesn't have key to match kid or alg from Jwt` |
   | extra: wrong `aud` | -> Waypoint JWT filter | Waypoint | **403** `Audiences in Jwt are not allowed` |
   | extra: wrong `iss` | -> Waypoint JWT filter | Waypoint | **401** `Jwt issuer is not configured` |

   Scenario 3's test pod needs `serviceAccountName: svc-a-sa` via `--overrides` or a committed manifest.
11. **README troubleshooting additions**: "Waypoint identity not allowed at ztunnel" (symptom: client gets an upstream error from the Waypoint rather than `RBAC: access denied` - exact status Unconfirmed, expect 503 - and the destination ztunnel logs `connection closed due to policy rejection: allow policies exist, but none allowed`), and "`forwardOriginalToken` false -> app returns 401 on the happy path".
