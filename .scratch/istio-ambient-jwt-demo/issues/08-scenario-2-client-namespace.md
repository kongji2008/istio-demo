# 08: verify.sh scenario 2: which namespace does the rogue client run in?

Type: grilling
Status: resolved
Blocked by:

## Question

The brief says scenario 2 runs a curl pod in `default` and expects `RBAC: access denied`. Research 03 shows that a **non-mesh** client is dropped by ztunnel at L4 (TCP reset, curl exit 56/52, no HTTP body): the `RBAC: access denied` body only appears when the client is itself ambient-enrolled so its traffic traverses service-a's Waypoint. Options:

- (a) Label `default` with `istio.io/dataplane-mode: ambient` in `00-namespaces.yaml` and keep the brief's expectation verbatim. Cheapest; but `default` is a shared namespace and labelling it is a side effect a reviewer may question.
- (b) Add a dedicated `rogue-ns` (ambient-labelled, no SA allow anywhere) and run scenario 2 there; expectation stays `RBAC: access denied`. Cleaner story: "a mesh member with the wrong identity".
- (c) Keep the client in unlabelled `default` and change the expected result to "connection refused/reset at L4, no HTTP response", which demonstrates ztunnel's L4 denial instead of the waypoint's.
- (d) Run both (b) and (c) as scenarios 2a/2b: shows the two enforcement layers distinctly.

Recommendation: **(d)**. Two curl invocations, and it is the clearest illustration of the L4/L7 split the demo exists to show.

## Answer

**(d)**, decided by the user on 2026-09-17. Scenario 2 splits into two:

- **2a: in-mesh, wrong identity.** New namespace `rogue-ns` labelled `istio.io/dataplane-mode: ambient`, its own Deny-All Baseline, no allow rule anywhere references its SA. A curl pod there calls `service-a.svc-a-ns:8080/hello`; traffic traverses service-a's Waypoint and is rejected at L7 → expect HTTP **403** with body `RBAC: access denied`.
- **2b: outside the mesh.** A curl pod in the unlabelled `default` namespace makes the same call in plaintext; ztunnel rejects it at L4 under `PeerAuthentication STRICT` → expect **no HTTP response**, TCP reset (curl exit 56 or 52; verify.sh must accept either, per research 03's unconfirmed item).

Consequences: `00-namespaces.yaml` gains `rogue-ns`; `30-deny-all.yaml` gains a fourth deny-all; verify.sh prints PASS/FAIL for 2a and 2b separately. 2b is also the only scenario that exercises `PeerAuthentication STRICT` (spec Istio requirement 6).
