#!/usr/bin/env bash
# Usage: mint-jwt.sh <private.pem> [ttl-seconds] [kid] [sub] [tenant_id]
# Mints an RS256 Internal JWT with the same claims the Portal mints (research 04 §2). ttl may be
# negative for an already-expired token; use -120 or lower because Envoy allows 60 s clock skew.
set -euo pipefail
KEY="$1"; TTL="${2:-300}"; KID="${3:-portal-key-1}"; SUB="${4:-alice}"; TENANT="${5:-tenant-001}"

b64url() { base64 | tr -d '\n=' | tr '+/' '-_'; }

NOW=$(date +%s)
# `tr -d '\n'` strips jq's trailing newline, which would otherwise be base64-encoded into the header and break the token.
HEADER=$(jq -cn --arg kid "$KID" '{alg:"RS256",kid:$kid,typ:"JWT"}' | tr -d '\n' | b64url)
PAYLOAD=$(jq -cn --arg sub "$SUB" --arg tenant "$TENANT" --argjson iat "$NOW" --argjson exp "$((NOW + TTL))" \
  '{iss:"https://portal.internal",aud:"internal-services",sub:$sub,tenant_id:$tenant,roles:["USER"],iat:$iat,exp:$exp}' \
  | tr -d '\n' | b64url)
# Never `echo` into dgst: echo appends "\n" and the signature would cover the wrong bytes.
SIG=$(printf '%s.%s' "$HEADER" "$PAYLOAD" | openssl dgst -sha256 -sign "$KEY" -binary | b64url)
printf '%s.%s.%s\n' "$HEADER" "$PAYLOAD" "$SIG"
