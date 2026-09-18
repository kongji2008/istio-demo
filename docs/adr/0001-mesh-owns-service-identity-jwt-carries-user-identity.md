---
status: accepted
---
# Mesh owns service identity; a portal-minted internal JWT carries end-user identity

Services need to know both *which service* is calling and *which user* the call is for. We delegate the first entirely to Istio ambient (ztunnel mTLS + SPIFFE principals, `AuthorizationPolicy`), and carry the second in a short-lived RS256 JWT that the Portal mints per downstream call; the browser session never leaves the Portal. Application code therefore contains no mTLS, certificate, SPIFFE, or ServiceAccount-token handling, which is the property this demo exists to prove.

## Considered Options

- **Token relay of the browser session / an upstream OAuth2 access token**: rejected, it leaks a long-lived credential across trust boundaries and couples downstream services to the IdP.
- **Plain header propagation (`X-User-Id`)**: rejected, unsigned headers can be forged by any workload the mesh already admits.
- **Application-level mTLS or SA-token exchange**: rejected, duplicates what the mesh provides and puts identity plumbing in every service.

## Consequences

Service identity and end-user identity are checked by *different* enforcement points (ztunnel/waypoint vs. waypoint + app). Authorization rules must require both (`principals` **and** `requestPrincipals`).
