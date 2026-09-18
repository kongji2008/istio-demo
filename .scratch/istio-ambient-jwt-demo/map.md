# Map: Istio Ambient + Internal JWT Demo

Label: wayfinder:map
Tracker: local markdown (`.scratch/istio-ambient-jwt-demo/`). Tickets live in `issues/`, research notes in `research/`.

## Destination

A **decision-complete build brief** for the demo described in [spec.md](./spec.md): every design choice locked, every Istio/Spring fact the implementer would otherwise have to discover already verified against primary sources, and the local toolchain (kind, istioctl, colima, JDK 21) in place. Reaching it means one implementation session can build the repo and run `scripts/verify.sh` to 6/6 PASS without stopping to decide anything. Building the demo itself is **not** on this map.

## Notes

- **Language**: every artifact (code, comments, YAML, scripts, README, `.scratch` files, ADRs) is in **English**. Chinese is used only in conversation with the user.
- **Skills**: `mattpocock-skills:grilling` + `mattpocock-skills:domain-modeling` for HITL tickets; `mattpocock-skills:research` for AFK research tickets. Glossary in `/CONTEXT.md`; ADRs in `/docs/adr/`. Use glossary terms (Service Identity, End-User Identity, Internal JWT, Browser Session, Waypoint, Deny-All Baseline, Ingress Gateway, Authorization Decision Point).
- **Safety**: the user's kubeconfig current context may be a **real cluster**. Every script must pin `--context kind-istio-demo` (or `KUBECONFIG` to a kind-only file) and refuse to run against anything else. Never run `kubectl` without a context in this repo.
- **Local environment (verified 2026-09-17)**: macOS 26 arm64; Docker CLI via **colima 0.10.3** (daemon not running by default; no Docker Desktop); `kind` 0.33.0 and `istioctl` 1.31.0 installed by the user on 2026-09-17 (see ticket 06); JDK 21 = Homebrew openjdk@21 21.0.12 (`/usr/libexec/java_home -v 21`; the `jenv` shim for 21.0.8 is broken, do not rely on `java` on PATH); Maven 3.9.16; openssl, jq present.
- **Versions**: Kubernetes **1.35** (mirror the user's real clusters), Istio **1.31** (latest stable per user). Pin both explicitly in `scripts/setup-cluster.sh`.
- **Standing assumptions** (approved by user): Service A forwards the Portal's Internal JWT unchanged (no re-signing); kind cluster name `istio-demo`.
- **Research notes** go to `research/<slug>.md`, one file per research ticket, every claim cited to a primary source. Research subagents edit only their own ticket file and research file; the map is updated by the driving session.

## Decisions so far

- [01 Charting decisions (grilling round 1)](./issues/01-charting-decisions.md): destination is a build brief, not the build; Gateway API `Gateway` in a dedicated `istio-ingress` ns; English everywhere; `scripts/mint-jwt.sh` (openssl) mints test tokens; `kubectl port-forward` for verify.sh plus kind extraPortMappings for browser demos; CSRF disabled in Portal; K8s 1.35 / Istio 1.31; users `alice/tenant-001` and `bob/tenant-002`. ADRs 0001–0003 written.
- [05 Spring Boot line](./issues/05-spring-boot-line.md): **Spring Boot 4.x** (org baseline; user override of the recommended 3.5.x). Spring Security 7, Jackson 3; pin exact patch at brief assembly.
- [04 openssl JWK + RS256 recipes](./issues/04-research-openssl-jwk-and-rs256-recipes.md): tested `pem-to-jwk` / `mint-jwt` / `verify-jwt` shell recipes (OpenSSL 3 and LibreSSL identical); Envoy allows 60 s skew so the expired demo token must be ≥120 s old; Boot 4 starter is `spring-boot-starter-security-oauth2-resource-server`, add `spring-boot-starter-restclient`; set `kid=portal-key-1` explicitly in `NimbusJwtEncoder` or the waypoint 401s silently. Details: [research note](./research/openssl-jwk-and-rs256-recipes.md).
- [03 Ambient authz semantics](./issues/03-research-ambient-authz-semantics.md): namespace deny-all is enforced by ztunnel only, never by the Waypoint; the waypoint→workload hop carries the **waypoint's** SA, so `svc-a-ns` and `svc-b-ns` each need an unconditional L4 `allow-waypoint-to-<svc>` (spec item 8's "if" is wrong) plus a waypoint-bound allow-nothing via `targetRefs: Gateway`; both `allow-portal-to-a` and `allow-a-to-b` must bind `targetRefs: Service`; `RequestAuthentication` needs `forwardOriginalToken: true` or the in-app check 401s on the happy path; no-token → **403** `RBAC: access denied`, bad/expired token → **401**; a non-mesh `default`-ns client is dropped at L4 with no HTTP body, so scenario 2 needs an ambient-labelled client namespace to see `RBAC: access denied`; ADR-0002 confirmed. Details: [research note](./research/ambient-authz-semantics.md).
- [06 Install local toolchain](./issues/06-task-install-local-toolchain.md): kind 0.33.0, istioctl 1.31.0 at `/opt/homebrew/bin`, colima 4 CPU / 8 GiB running. Cluster not yet created.
- [02 Istio 1.31 / kind 1.35 install facts](./issues/02-research-istio-1-31-kind-1-35-install-facts.md): Istio 1.31.0 + K8s 1.35 is a supported pair; kind v0.33.0 image `kindest/node:v1.35.8@sha256:07b2…` (must pass `--image`, default is 1.37); Gateway API v1.6.0 experimental; no kind platform flag; waypoint `Gateway` name/SA `waypoint`; ingress gateway SA `<name>-istio`; gateway ns not ambient-labelled. Details: [research note](./research/istio-1-31-kind-1-35-install-facts.md).
- [08 Scenario 2 client namespace](./issues/08-scenario-2-client-namespace.md): split into **2a** (ambient-labelled `rogue-ns`, wrong identity → Waypoint 403 `RBAC: access denied`) and **2b** (unlabelled `default`, plaintext → ztunnel L4 reset, no HTTP; also the only test of `PeerAuthentication STRICT`).
- [07 Assemble the build brief](./issues/07-task-assemble-build-brief.md): `/BUILD-BRIEF.md` written; all fog closed (nested JSON response asserted via jq; committed test pods in `90-test-pods.yaml`; writing-plans → executing-plans with four checkpoints). **Destination reached: the way is clear; no open tickets.**

## Not yet specified

_None. All fog graduated or closed in ticket 07; routine leftovers are listed in `BUILD-BRIEF.md` §10._

## Out of scope

- Database, frontend framework, OPA engine (a named Authorization Decision Point hook only), observability, production key management (per spec non-goals).
- Running anything against the user's real clusters.
- Building the demo itself (follow-on implementation session, fed by this map's brief).
