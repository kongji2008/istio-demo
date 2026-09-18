# 07: Task: assemble the build brief

Type: task
Status: resolved
Blocked by: 02, 03, 04, 05, 06, 08

## Question

Produce the destination artifact: a single `BUILD-BRIEF.md` at the repo root (English) that an implementation session can execute end to end without deciding anything. Contents:

1. `spec.md` requirements, amended in place with every decision from the map (do not leave the implementer to reconcile two documents).
2. The verified facts from research 02/03/04 that change YAML or scripts: exact versions and image tags, install commands, the corrected policy layout (any L4 allows for waypoint SAs, RequestAuthentication binding, gateway SA principal), expected denial responses per verify.sh scenario, the tested openssl recipes.
3. The fog items still under "Not yet specified" on the map, each either resolved here (response shape of `/api/hello`; scenario-3 pod mechanics) or explicitly delegated as routine to the implementer.
4. The safety rule: pin `--context kind-istio-demo` everywhere.
5. The chosen implementation method (single run vs. `superpowers:writing-plans` + `executing-plans`) with a one-line reason.

When done, the map's destination is reached: close this ticket, and note on the map that the way is clear.

## Answer

Written: [/BUILD-BRIEF.md](../../../BUILD-BRIEF.md) (English). It merges `spec.md` with all decisions (tickets 01, 05, 08) and verified facts (research 02, 03, 04): version pins (K8s 1.35.8 image, Istio 1.31.0, Gateway API v1.6.0 experimental, Spring Boot 4.1.1), the corrected policy layout (waypoint L4 allows in both namespaces, waypoint-scoped allow-nothing, `targetRefs: Service` on both L7 policies, `forwardOriginalToken: true`), exact per-scenario expectations (10 checks incl. 2a/2b), tested shell recipes by reference, Boot 4 starter names and the `kid` pitfall.

Fog items closed here: `/api/hello` response is nested `{"via", "downstream": ...}` asserted via `jq`; scenario clients are committed long-running pods in `k8s/90-test-pods.yaml` (not `kubectl run --overrides`); implementation method is `superpowers:writing-plans` → `executing-plans` with four checkpoints. Remaining routine items are listed in the brief's §10.

Destination reached.
