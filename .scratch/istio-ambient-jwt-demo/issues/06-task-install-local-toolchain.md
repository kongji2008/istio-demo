# 06: Task: install kind + istioctl 1.31 and size colima

Type: task
Status: resolved
Blocked by: 02

## Question

Make the local machine ready for the implementation session, using the exact versions research 02 confirms:

1. `brew install kind` (or pinned formula/binary if Homebrew's kind lacks a 1.35 node image).
2. Install istioctl 1.31 for macOS arm64 (method per research 02) and verify `istioctl version --remote=false`.
3. Start colima with resources adequate for kind + Istio ambient + 3 services + 2 waypoints + 1 gateway (propose 4 CPU / 8 GiB / 60 GiB disk; record what was used) and confirm `docker info` works.
4. Do **not** create the kind cluster; that is `scripts/setup-cluster.sh`'s job in the implementation session.

Record versions installed, commands used, and anything that deviated in the `## Answer`.

## Answer

Installed by the user manually on 2026-09-17:

- kind v0.33.0 via Homebrew (`/opt/homebrew/Cellar/kind/0.33.0`). Node image for K8s 1.35 is `kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0` (research 02); kind defaults to 1.37 without `--image`, so `setup-cluster.sh` must pass it.
- istioctl 1.31.0 (osx-arm64) via `downloadIstio`, release tree moved to `~/.local/istio-1.31.0`, symlinked at `/opt/homebrew/bin/istioctl`. `istioctl version --remote=false` → `client version: 1.31.0`.
- colima started with `--cpu 4 --memory 8 --disk 60` (disk not reduced: existing instance already larger). Docker socket `unix://$HOME/.colima/default/docker.sock`; `docker info` OK (bridge-nf-call warnings are harmless for kind).
- No kind cluster created; that remains `scripts/setup-cluster.sh`'s job.
