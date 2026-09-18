# 01: Charting decisions (grilling round 1)

Type: grilling
Status: resolved
Blocked by:

## Question

Name the destination and settle the design choices the user's brief leaves open before any implementation can start.

## Answer

Resolved with the user on 2026-09-17. Recommendations were accepted unless noted.

| # | Question | Decision |
|---|---|---|
| Q1 | Destination | (a) A decision-complete build brief; the build is a follow-on session. |
| Q2 | Ingress | Kubernetes Gateway API `Gateway` + `HTTPRoute`, Istio-managed, in a dedicated `istio-ingress` namespace. Rationale: the Deny-All Baseline in `portal-ns` would be enforced by the gateway's own Envoy and reject browser traffic. See ADR-0002. `allow-gw-to-portal` principal = the gateway's generated SA (exact name: research 02). |
| Q3 | Language | **User override**: English for all code, comments, scripts, and every Markdown file. Chinese only in conversation. |
| Q4 | Test tokens for verify.sh 4/5/6 | New `scripts/mint-jwt.sh` signing RS256 with openssl. The "no hand-rolled base64" rule applies to Java, not test scripts. Deliverable tree gains one file. |
| Q5 | Host → gateway | `kubectl port-forward` to the Gateway Service in verify.sh; also add kind `extraPortMappings` so the user can open the login page in a browser. |
| Q6 | CSRF | Disabled in Portal with a one-line "why" comment (curl-driven login; not in demo scope). |
| Q7 | Versions | **User override**: Kubernetes **1.35** (matches the user's real clusters), Istio **1.31**. Pin both in `setup-cluster.sh`. |
| Q8 | Demo users | `alice/tenant-001` and `bob/tenant-002`, so scenario 1 shows different tenants propagating. |

Standing assumptions stated and not objected to: Service A forwards the Portal's Internal JWT unchanged; container runtime is colima; kind cluster name `istio-demo`.

ADRs written: 0001 (mesh owns service identity, JWT carries user identity), 0002 (gateway in dedicated namespace), 0003 (inline JWKS).
