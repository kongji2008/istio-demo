# Research: pure-shell PEM→JWK and RS256 minting recipes (ticket 04)

Status: complete (2026-09-17)

Scope: what `scripts/gen-keys.sh` and `scripts/mint-jwt.sh` need — RSA key pair + public JWK for `RequestAuthentication.jwks`, and RS256 JWTs (valid / expired / forged) minted with only `openssl`, `base64`, `jq`, `xxd`, POSIX `sh` on macOS. Consumers on the other side: Istio waypoint (Envoy `jwt_authn`) and Spring Boot 4 / Spring Security 7 (Nimbus).

Test machine (2026-09-17): macOS (Darwin 25.6), `/opt/homebrew/bin/openssl` = OpenSSL 3.6.4, `/usr/bin/openssl` = LibreSSL 3.3.6, `jq-1.7.1-apple`, BSD `base64`, `/usr/bin/xxd`, JDK 21 (`/usr/libexec/java_home -v 21`). All scratch files lived in the session scratchpad, not the repo.

---

## 1. PEM public key → JWK (`n`, `e` as base64url, no padding) — DONE

### Why the "leading 00" is a non-issue with `-modulus`

In DER, an RSA modulus is a positive INTEGER whose top bit is set, so the encoding carries a `00` sign byte (RSA-2048 modulus INTEGER is 257 bytes long: `hl=4 l= 257` below). JWK `n` must be the **magnitude only**: RFC 7518 §6.3.1.1 says `n` is a Base64urlUInt, and §2 defines Base64urlUInt as the "big-endian representation of an unsigned integer" that "MUST utilize the minimum number of octets needed to represent the value" (https://www.rfc-editor.org/rfc/rfc7518#section-6.3.1.1, https://www.rfc-editor.org/rfc/rfc7518#section-2). `openssl rsa -modulus` prints the hex magnitude with no sign byte, so no stripping is needed. Proof:

```
$ openssl rsa -pubin -in portal.pub -RSAPublicKey_out -outform DER | openssl asn1parse -inform DER | head -3
    0:d=0  hl=4 l= 266 cons: SEQUENCE
    4:d=1  hl=4 l= 257 prim: INTEGER           :C80B1C69C77A84...   <- DER shows 257-byte INTEGER (00 + 256)
  265:d=1  hl=2 l=   3 prim: INTEGER           :010001
$ openssl rsa -pubin -in portal.pub -noout -modulus | cut -c1-20
Modulus=C80B1C69C77A                                                  <- -modulus: 512 hex chars, no 00
```

(`asn1parse` prints INTEGER values as magnitude too; the `l= 257` length is what reveals the sign byte.)

### Tested recipe: `pem-to-jwk.sh`

```bash
#!/bin/sh
# Usage: pem-to-jwk.sh <public.pem> <kid>   (needs openssl, xxd, base64, jq)
set -eu
PUB="$1"; KID="${2:-portal-key-1}"
: "${OPENSSL:=openssl}"

b64url() { base64 | tr -d '\n=' | tr '+/' '-_'; }

# Modulus: `-modulus` prints the big-endian hex magnitude with NO leading 00
# (the DER INTEGER sign byte is not part of the number). 512 hex chars for RSA-2048.
MOD_HEX=$("$OPENSSL" rsa -pubin -in "$PUB" -noout -modulus | sed 's/^Modulus=//')
N=$(printf '%s' "$MOD_HEX" | xxd -r -p | b64url)

# Exponent: OpenSSL prints "Exponent: 65537 (0x10001)". Take the decimal, render as
# minimal big-endian bytes (odd hex length -> prepend one 0 so xxd gets whole bytes).
EXP_DEC=$("$OPENSSL" rsa -pubin -in "$PUB" -noout -text | sed -n 's/^Exponent: \([0-9]*\).*/\1/p')
EXP_HEX=$(printf '%x' "$EXP_DEC")
case $(( ${#EXP_HEX} % 2 )) in 1) EXP_HEX="0$EXP_HEX";; esac
E=$(printf '%s' "$EXP_HEX" | xxd -r -p | b64url)

jq -n --arg kid "$KID" --arg n "$N" --arg e "$E" \
  '{keys:[{kty:"RSA",use:"sig",alg:"RS256",kid:$kid,n:$n,e:$e}]}'
```

Key generation used for the test (same commands `gen-keys.sh` should use):

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out portal.key   # PKCS#8 "BEGIN PRIVATE KEY"
openssl pkey -in portal.key -pubout -out portal.pub                            # SPKI  "BEGIN PUBLIC KEY"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out other.key    # for the forged token
```

### Test output

```
$ OPENSSL=/opt/homebrew/bin/openssl ./pem-to-jwk.sh portal.pub portal-key-1 > jwks.json
$ OPENSSL=/usr/bin/openssl        ./pem-to-jwk.sh portal.pub portal-key-1 > jwks-libre.json
$ diff jwks.json jwks-libre.json && echo IDENTICAL
IDENTICAL                                        <- OpenSSL 3 and LibreSSL 3.3.6 agree
$ cat jwks.json
{"keys":[{"kty":"RSA","use":"sig","alg":"RS256","kid":"portal-key-1",
  "n":"yAscacd6hMjgAUeXjpYLykmW3Wx1A7dsHelOlBBJshMKMDWhkQOlK-nOmiAs_nYr...ouu2NjkalhJOh_fpMhHMUeqHp4w",
  "e":"AQAB"}]}

# n must decode to exactly 256 bytes for RSA-2048, first byte != 0x00:
$ N=$(jq -r '.keys[0].n' jwks.json); s=$(printf '%s' "$N" | tr '_-' '/+')
$ case $(( ${#s} % 4 )) in 2) s="$s==";; 3) s="$s=";; esac
$ printf '%s' "$s" | base64 -d | wc -c
     256
$ printf '%s' "$s" | base64 -d | xxd -l 4
00000000: c80b 1c69                                <- matches Modulus=C80B1C69..., no leading 00
$ printf 'AQAB' | base64 -d | xxd -p
010001                                             <- e = 65537
```

### Notes for the implementer

- `base64url` per RFC 7515 Appendix C: standard base64, `+`→`-`, `/`→`_`, padding `=` removed, no line breaks (https://www.rfc-editor.org/rfc/rfc7515#appendix-C). `tr -d '\n='` handles both padding and any wrapping.
- macOS BSD `base64` does not wrap by default and has no `-w`; GNU coreutils `base64` wraps at 76 chars. The `tr -d '\n'` in `b64url()` makes the recipe portable to Linux CI, so keep it even though it is a no-op on macOS. Do **not** use `base64 -w0` (fails on macOS).
- `openssl rsa -pubin -text` output format (`Exponent: 65537 (0x10001)`) is identical in OpenSSL 3 and LibreSSL; the `sed` handles both. `openssl pkey -pubin -in x -text_pub` is an alternative but `rsa` was tested on both.
- `xxd -r -p` requires an even number of hex digits; the modulus is always even-length for standard key sizes, and the exponent branch pads explicitly.
- `-RSAPublicKey_out` (PKCS#1 form) exists in both builds but is only used above for the proof, not in the recipe.

---

## 2. RS256 minting with `openssl dgst -sha256 -sign` — DONE

RS256 = RSASSA-PKCS1-v1_5 with SHA-256 (RFC 7518 §3.3, https://www.rfc-editor.org/rfc/rfc7518#section-3.3). `openssl dgst -sha256 -sign key.pem` produces exactly that (PKCS#1 v1.5 padding is `dgst`'s default for RSA keys). The JWS signing input is `ASCII(BASE64URL(header) || '.' || BASE64URL(payload))` (RFC 7515 §5.1, https://www.rfc-editor.org/rfc/rfc7515#section-5.1) — no trailing newline, hence `printf '%s.%s'` and `jq -c` + `tr -d '\n'`.

### Tested recipe: `mint-jwt.sh`

```bash
#!/bin/sh
# Usage: mint-jwt.sh <private.pem> [ttl-seconds] [kid] [sub] [tenant_id]
# ttl may be negative to mint an already-expired token. Prints the compact JWS.
set -eu
KEY="$1"; TTL="${2:-300}"; KID="${3:-portal-key-1}"; SUB="${4:-alice}"; TENANT="${5:-tenant-001}"
: "${OPENSSL:=openssl}"

b64url() { base64 | tr -d '\n=' | tr '+/' '-_'; }

NOW=$(date +%s)
HEADER=$(jq -cn --arg kid "$KID" '{alg:"RS256",kid:$kid,typ:"JWT"}' | tr -d '\n' | b64url)
PAYLOAD=$(jq -cn --arg sub "$SUB" --arg tenant "$TENANT" --argjson iat "$NOW" --argjson exp "$((NOW + TTL))" \
  '{iss:"https://portal.internal",aud:"internal-services",sub:$sub,tenant_id:$tenant,roles:["USER"],iat:$iat,exp:$exp}' \
  | tr -d '\n' | b64url)
SIG=$(printf '%s.%s' "$HEADER" "$PAYLOAD" | "$OPENSSL" dgst -sha256 -sign "$KEY" -binary | b64url)
printf '%s.%s.%s\n' "$HEADER" "$PAYLOAD" "$SIG"
```

The three demo tokens:

```bash
./mint-jwt.sh portal.key 300  > valid.jwt     # exp = now+5min
./mint-jwt.sh portal.key -60  > expired.jwt   # exp = now-60s, signature still valid
./mint-jwt.sh other.key  300  > forged.jwt    # right kid/claims, wrong key
```

### Tested verifier: `verify-jwt.sh` (openssl-only round trip)

```bash
#!/bin/sh
# Usage: verify-jwt.sh <public.pem> <token>   -- checks RS256 signature with openssl and prints claims
set -eu
PUB="$1"; TOK="$2"; : "${OPENSSL:=openssl}"
b64url_dec() { s=$(printf '%s' "$1" | tr '_-' '/+'); case $(( ${#s} % 4 )) in 2) s="$s==";; 3) s="$s=";; esac; printf '%s' "$s" | base64 -d; }
H=${TOK%%.*}; REST=${TOK#*.}; P=${REST%%.*}; S=${REST#*.}
b64url_dec "$S" > "${TMPDIR:-/tmp}/sig.$$"
printf '%s.%s' "$H" "$P" | "$OPENSSL" dgst -sha256 -verify "$PUB" -signature "${TMPDIR:-/tmp}/sig.$$" && RC=0 || RC=$?
rm -f "${TMPDIR:-/tmp}/sig.$$"
echo "header:  $(b64url_dec "$H" | jq -c .)"
echo "payload: $(b64url_dec "$P" | jq -c .)"
NOW=$(date +%s); EXP=$(b64url_dec "$P" | jq -r .exp); [ "$EXP" -gt "$NOW" ] && echo "exp: ok ($((EXP-NOW))s left)" || echo "exp: EXPIRED ($((NOW-EXP))s ago)"
exit $RC
```

### Test output

```
--- valid.jwt  (minted with OpenSSL 3, verified with OpenSSL 3)
Verified OK
header:  {"alg":"RS256","kid":"portal-key-1","typ":"JWT"}
payload: {"iss":"https://portal.internal","aud":"internal-services","sub":"alice","tenant_id":"tenant-001","roles":["USER"],"iat":1789691105,"exp":1789691405}
exp: ok (300s left)
exit=0
--- expired.jwt
Verified OK
header:  {"alg":"RS256","kid":"portal-key-1","typ":"JWT"}
payload: {...,"iat":1789691105,"exp":1789691045}
exp: EXPIRED (60s ago)
exit=0                                  <- signature valid; only the exp check fails (as intended)
--- forged.jwt  (signed with other.key)
...rsa routines:RSA_padding_check_PKCS1_type_1:invalid padding...
Verification failure
header:  {"alg":"RS256","kid":"portal-key-1","typ":"JWT"}
payload: {...}
exit=1
--- valid-libre.jwt  (minted with /usr/bin/openssl LibreSSL 3.3.6, verified with OpenSSL 3)
Verified OK
exit=0
--- valid-libre.jwt verified with LibreSSL verifier
Verified OK
exit=0

$ cat valid.jwt
eyJhbGciOiJSUzI1NiIsImtpZCI6InBvcnRhbC1rZXktMSIsInR5cCI6IkpXVCJ9.eyJpc3MiOi...MTQwNX0.e1N7DLg8cDV3U6w9M2rmmKbq5eguR6WUSDs08ZMt0i3yOM...ZWPWaRQKGxMWLlo5QaNFMxA
segments=3 header_len=64 sig_len=342     <- 256-byte signature -> 342 base64url chars, no '=' '+' '/'
```

### Notes for the implementer

- `date +%s` is POSIX-enough for both BSD and GNU `date`. Negative TTL for the expired token is plain shell arithmetic.
- `jq -c` already emits one line; the extra `tr -d '\n'` strips jq's trailing newline, which would otherwise be base64-encoded into the header and break the token.
- `openssl dgst -sign` with a PKCS#8 (`BEGIN PRIVATE KEY`) file works on both builds. LibreSSL 3.3.6 also signs fine; the only observable difference was the error text on verification failure (OpenSSL 3 prints provider-routine errors, LibreSSL prints classic `rsa routines` lines); the exit code is 1 in both.
- Do not `echo` the token into `dgst` — `echo` appends `\n` and the signature would cover the wrong bytes.
- `openssl dgst -verify` needs the raw signature bytes in a file; that is why the verifier writes `sig.$$` to `$TMPDIR`.

### Cross-check with Nimbus JOSE + JWT (the library Spring Security uses)

`NimbusVerify.java` (scratchpad, not committed) parses the shell-built `jwks.json` with `JWKSet.parse`, and verifies each shell-minted token with `RSASSAVerifier`. Run with JDK 21 and `nimbus-jose-jwt-10.9.1.jar` from `~/.m2`:

```
JWK kid=portal-key-1 modulus bits=2048 e=65537
valid.jwt       header={kid=portal-key-1, typ=JWT, alg=RS256} sig=VALID   expired=false tenant_id=tenant-001
expired.jwt     header={kid=portal-key-1, typ=JWT, alg=RS256} sig=VALID   expired=true  tenant_id=tenant-001
forged.jwt      header={kid=portal-key-1, typ=JWT, alg=RS256} sig=INVALID expired=false tenant_id=tenant-001
valid-libre.jwt header={kid=portal-key-1, typ=JWT, alg=RS256} sig=VALID   expired=false tenant_id=tenant-001
```

`modulus bits=2048` from the JWK confirms `n` has no stray leading byte (a leading `00` would still give 2048 bits in BigInteger, but a 257-byte `n` would be rejected by strict validators and is non-conformant per RFC 7518 §2). The `256`-byte check above is the strict proof.

### LibreSSL (`/usr/bin/openssl`) compatibility — DONE

Whole pipeline re-run with **only** LibreSSL 3.3.6: `genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048` → `pkey -pubout` → `pem-to-jwk.sh` → `mint-jwt.sh`, then verified with OpenSSL 3:

```
==> k.key <==  -----BEGIN PRIVATE KEY-----
==> k.pub <==  -----BEGIN PUBLIC KEY-----
LibreSSL genpkey+pkey -> JWK identical on both builds
Verified OK
```

Conclusion: the scripts work unchanged with a bare macOS (`/usr/bin/openssl`) and with Homebrew OpenSSL 3. No `-provider`, `-traditional`, or `rsa -RSAPublicKey_in` differences are hit because the recipe sticks to `genpkey`, `pkey -pubout`, `rsa -pubin -modulus/-text`, `dgst -sign/-verify`.

---

## 3. What Istio `RequestAuthentication` inline `jwks` actually needs — DONE

### Istio API surface

- `jwtRules[].jwks`: "JSON Web Key Set of public keys to validate signature of the JWT." `jwksUri`: "URL of the provider's public key set to validate signature of the JWT." `issuer`: "Identifies the issuer that issued the JWT" (tokens with a different `iss` are rejected). `audiences`: "A JWT containing any of these audiences will be accepted." Source: https://istio.io/latest/docs/reference/config/security/request_authentication/
- "A request that does not contain any authentication credentials will be accepted but will not have any authenticated identity. To restrict access to authenticated requests only, this should be accompanied by an authorization rule." Same source. Invalid/expired token → 401 from the proxy; missing token → allowed unless an `AuthorizationPolicy` requires `requestPrincipals`. Task page: https://istio.io/latest/docs/tasks/security/authentication/authn-policy/ ("requests without tokens are accepted").
- `AuthorizationPolicy.rules[].from.source.requestPrincipals`: "The request identity is in the format of `"<ISS>/<SUB>"`, for example, `"example.com/sub-1"`. This field requires request authentication enabled and is the same as the `request.auth.principal` attribute." So for this demo the principal is `https://portal.internal/alice`. Also: "Waypoint proxies are required to use this field [`targetRefs`] for policies to apply; `selector` policies will be ignored." Source: https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istiod maps a `JWTRule` 1:1 onto an Envoy `jwt_authn` `JwtProvider` (`Issuer`, `Audiences`, `Forward: forwardOriginalToken`, `ForwardPayloadHeader: outputPayloadToHeader`, `PayloadInMetadata`), and the inline `jwks` string goes through `JwtKeyResolver.BuildLocalJwks(jwksUri, issuer, jwks, timeout)` into `local_jwks.inline_string`; only `jwksUri` involves a fetch (by istiod in the default `PILOT_JWT_ENABLE_REMOTE_JWKS` mode). Source: https://github.com/istio/istio/blob/master/pilot/pkg/security/authn/policy_applier.go. Envoy `JwtProvider.local_jwks`: "JWKS is in local data source. It could be either in a local file or embedded in the inline_string." Source: https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/jwt_authn/v3/config.proto

### What the verifier (Envoy `jwt_authn`) checks — from its source, since the docs do not spell it out

Envoy's filter (`source/extensions/filters/http/jwt_authn/authenticator.cc`) checks `iss`/`aud` against the provider, then `verifyJwtWithoutTimeChecking(jwt, jwks)` and `jwt.verifyTimeConstraint(now, clock_skew)` (default skew 60 s). Source: https://github.com/envoyproxy/envoy/blob/main/source/extensions/filters/http/jwt_authn/authenticator.cc. The key-selection loop is in Envoy's vendored copy of google/jwt_verify_lib (`source/common/jwt/verify.cc`, identical logic to https://github.com/google/jwt_verify_lib/blob/master/src/verify.cc):

```
if (!jwt.kid_.empty() && !jwk->kid_.empty() && jwk->kid_ != jwt.kid_) continue;   // kid: only compared when BOTH have one
if (!jwk->alg_.empty() && jwk->alg_ != jwt.alg_) continue;                          // alg: only compared when the JWK has one
... branch on jwk->kty_ ("RSA" -> RS*/PS*) ...
return kid_alg_matched ? Status::JwtVerificationFail : Status::JwksKidAlgMismatch;
```

Source: https://github.com/envoyproxy/envoy/blob/main/source/common/jwt/verify.cc

JWK parsing (`jwks.cc`): `kty`, `n`, `e` required for RSA; `"kid" and "alg" are optional, if they do not exist, set them to empty`; if `alg` is present it must start with `RS` or `PS` (else `JwksRSAKeyBadAlg` = "[alg] is not started with [RS] or [PS] for an RSA key"); the `use` field is **never read**. `n`/`e` are base64url-decoded straight into `BN_bin2bn`. Sources: https://github.com/google/jwt_verify_lib/blob/master/src/jwks.cc, https://github.com/google/jwt_verify_lib/blob/master/src/status.cc

Resulting 401 bodies you will see from the waypoint: `Jwt is expired`, `Jwt verification fails`, `Jwks doesn't have key to match kid or alg from Jwt`, `Jwt issuer is not configured`, `Audiences in Jwt are not allowed`.

### Answers to the ticket's sub-questions

| Question | Answer | Basis |
|---|---|---|
| Is `alg` required in the JWK? | No. Optional per RFC 7517 §4.4 and per Envoy. If present it must match the JWT's `alg` exactly and start with `RS`/`PS` for RSA. Including `"alg":"RS256"` is harmless and pins the key to one algorithm — keep it. | RFC 7517 https://www.rfc-editor.org/rfc/rfc7517#section-4.4; verify.cc |
| Is `use` required? | No. Optional per RFC 7517 §4.2; Envoy ignores it entirely. Keep `"use":"sig"` for readers, it has no runtime effect. | RFC 7517 §4.2; jwks.cc |
| Must the JWT `kid` match the JWK `kid`? | Only if **both** are present — then they must be equal, otherwise the key is skipped and you get 401 `Jwks doesn't have key to match kid or alg from Jwt`. If either side omits `kid`, every key of the right `kty` is tried. Because the demo JWKS has `kid: portal-key-1`, the portal **must** put exactly `portal-key-1` in the JWS header (see §4 for the Spring pitfall). | verify.cc; RFC 7515 §4.1.4 (kid is a "hint") |
| Minimum JWK | `{"kty":"RSA","n":"...","e":"AQAB"}` inside `{"keys":[...]}`; RFC 7517 §5 `keys` is an array. `kty` is the only REQUIRED member (RFC 7517 §4.1). | RFC 7517 §4.1, §5 |

Recommended JWK for `RequestAuthentication.jwks` (what `pem-to-jwk.sh` emits): `{"keys":[{"kty":"RSA","use":"sig","alg":"RS256","kid":"portal-key-1","n":"...","e":"AQAB"}]}`. Paste as a YAML block scalar (`jwks: |`) — the spec already shows this shape.

Two further Istio points relevant to the scripts:

- Inline `jwks` means no istiod fetch, so the `portal-ns` deny-all cannot break it (this is the known pitfall the spec calls out). Key rotation = edit the `RequestAuthentication` and roll the portal Secret.
- Envoy applies a 60 s clock-skew allowance on `exp`/`nbf`. `mint-jwt.sh portal.key -60` lands exactly on the edge; use `-120` (or lower) for the demo's expired token so the waypoint rejects it deterministically. (Spring's `JwtTimestampValidator` also defaults to 60 s skew.)

---

## 4. Spring Boot 4.x / Spring Security 7 side — DONE

### Resource server (`service-a`, `service-b`): raw public key

- Property: `spring.security.oauth2.resourceserver.jwt.public-key-location` — "Location of the file containing the public key used to verify a JWT." (type `Resource`, so `classpath:`/`file:` prefixes work, e.g. `file:/etc/portal-keys/public.pem`). Boot 4 reference: "you can configure the resource server with the Public Key used for verifying the signature of the JWT. This can be done using the `spring.security.oauth2.resourceserver.jwt.public-key-location` property, where the value needs to point to a file containing the public key in the PEM-encoded x509 format." Sources: https://docs.spring.io/spring-boot/reference/security/oauth2.html (Boot 4.1.1), https://github.com/spring-projects/spring-boot/blob/main/module/spring-boot-security-oauth2-resource-server/src/main/java/org/springframework/boot/security/oauth2/server/resource/autoconfigure/OAuth2ResourceServerProperties.java
- What Boot does with it (`JwtDecoderConfiguration.jwtDecoderByPublicKeyValue`, `@ConditionalOnPublicKeyJwtDecoder`): strips `-----BEGIN PUBLIC KEY-----` / `-----END PUBLIC KEY-----`, base64-decodes, `KeyFactory.getInstance("RSA")` + `X509EncodedKeySpec`, then `NimbusJwtDecoder.withPublicKey(key).signatureAlgorithm(exactlyOneAlgorithm()).build()` and `setJwtValidator(getValidator())`. Source: https://github.com/spring-projects/spring-boot/blob/main/module/spring-boot-security-oauth2-resource-server/src/main/java/org/springframework/boot/security/oauth2/server/resource/autoconfigure/JwtDecoderConfiguration.java
  - Consequence 1: the file **must** be SPKI/X.509 `BEGIN PUBLIC KEY` — exactly what `openssl pkey -pubout` writes. PKCS#1 `BEGIN RSA PUBLIC KEY` (from `openssl rsa -RSAPublicKey_out`) will not parse.
  - Consequence 2: `spring.security.oauth2.resourceserver.jwt.jws-algorithms` must contain exactly one value with the public-key path; default is `RS256` (property default `Arrays.asList("RS256")`), so leave it alone.
  - Consequence 3: validators — `exp`/`nbf` timestamp validation and `typ` validation are always on (Spring Security 7: "`JwtTypeValidator#jwt` is automatically added by all `createDefaultXXX` methods"); an `aud` validator is added only if `spring.security.oauth2.resourceserver.jwt.audiences` is set; an `iss` validator only if `issuer-uri` is set. **Set `audiences: internal-services`** so Layer 2 also enforces `aud`. Do **not** set `issuer-uri` (Boot would try OIDC discovery against `https://portal.internal`); if `iss` should be checked in-app, add a `JwtIssuerValidator`/`JwtClaimValidator` on a custom `JwtDecoder` bean instead. Sources: JwtDecoderConfiguration.java above; https://docs.spring.io/spring-security/reference/migration/servlet/oauth2.html; https://docs.spring.io/spring-security/reference/servlet/oauth2/resource-server/jwt.html
- Auto-config backs off when you define your own `JwtDecoder` bean (`@ConditionalOnMissingBean(JwtDecoder.class)`); the reference also says "Alternatively, you can define your own `JwtDecoder` bean". Programmatic equivalent (Security 7.1.1 reference, "Trusting a Single Asymmetric Key"): `NimbusJwtDecoder.withPublicKey(this.key).build()`; "By default, `NimbusJwtDecoder`, and hence Resource Server, will only trust and verify tokens using `RS256`." Source: https://docs.spring.io/spring-security/reference/servlet/oauth2/resource-server/jwt.html
- Claims → `SecurityContext`: `spring.security.oauth2.resourceserver.jwt.authorities-claim-name=roles`, `authority-prefix=ROLE_` map `roles: ["USER"]` to `ROLE_USER` with no code (properties documented in `OAuth2ResourceServerProperties`: "Name of token claim to use for mapping authorities from JWT.", "Prefix to use for authorities mapped from JWT."). `tenant_id` is read via `@AuthenticationPrincipal Jwt jwt` → `jwt.getClaimAsString("tenant_id")`.

### Portal: minting with `NimbusJwtEncoder`

Constructor: `public NimbusJwtEncoder(JWKSource<SecurityContext> jwkSource)` — "The private/secret key used for signing the JWS is supplied by the `com.nimbusds.jose.jwk.source.JWKSource` provided via the constructor." (Since 5.6; class present unchanged in Security 7.) Source: https://docs.spring.io/spring-security/reference/api/java/org/springframework/security/oauth2/jwt/NimbusJwtEncoder.html

Canonical construction from the official sample (`spring-security-samples/servlet/spring-boot/java/jwt/login`, works on 5.6 → 7.x):

```java
@Value("${jwt.public.key}")  RSAPublicKey  key;    // Boot converts a Resource/PEM string to RSAPublicKey
@Value("${jwt.private.key}") RSAPrivateKey priv;

@Bean JwtEncoder jwtEncoder() {
    JWK jwk = new RSAKey.Builder(this.key).privateKey(this.priv).keyID("portal-key-1").build(); // keyID added for Istio
    JWKSource<SecurityContext> jwks = new ImmutableJWKSet<>(new JWKSet(jwk));
    return new NimbusJwtEncoder(jwks);
}
```

Source: https://github.com/spring-projects/spring-security-samples/blob/main/servlet/spring-boot/java/jwt/login/src/main/java/example/RestConfig.java (sample has no `.keyID(...)`; added here — see kid pitfall below). The `@Value`→`RSAPublicKey`/`RSAPrivateKey` conversion works for a PEM `Resource` path such as `file:/etc/portal-keys/private.pem` (PKCS#8 `BEGIN PRIVATE KEY`, which is what `openssl genpkey` writes).

New in Spring Security 7.0 — builder API (optional, simpler): `NimbusJwtEncoder.withKeyPair(RSAPublicKey, RSAPrivateKey)` → `RsaKeyPairJwtEncoderBuilder` with `algorithm(SignatureAlgorithm)` ("Defaults to `SignatureAlgorithm.RS256`"), `jwkPostProcessor(Consumer<RSAKey.Builder>)` ("For example, you may use this to override the default kid"), `build()`; all `Since: 7.0`. Sources: https://docs.spring.io/spring-security/reference/api/java/org/springframework/security/oauth2/jwt/NimbusJwtEncoder.RsaKeyPairJwtEncoderBuilder.html, https://docs.spring.io/spring-security/reference/api/java/org/springframework/security/oauth2/jwt/NimbusJwtEncoder.html

```java
JwtEncoder enc = NimbusJwtEncoder.withKeyPair(pub, priv)
        .jwkPostProcessor(b -> b.keyID("portal-key-1"))
        .build();
```

**kid pitfall (this is the one that produces a silent 401 at the waypoint).** `NimbusJwtEncoder` copies the JWK's `kid` into the JWS header when the header has none (`addKeyIdentifierHeadersIfNecessary`: `if (!hasText(headers.getKeyId()) && hasText(jwk.getKeyID())) headersBuilder.keyId(jwk.getKeyID())`). The 7.0 `withKeyPair` builder gives the JWK a default kid via `RSAKey.Builder(...).keyIDFromThumbprint()` (`JWKS.signingWithRsa`) — a 43-char SHA-256 thumbprint, **not** `portal-key-1`. Since the JWKS in `RequestAuthentication` carries `kid: portal-key-1`, Envoy would skip the only key → `Jwks doesn't have key to match kid or alg from Jwt`. Either set `keyID("portal-key-1")` on the `RSAKey.Builder` (both constructions above do), or set it per token via `JwsHeader.with(SignatureAlgorithm.RS256).keyId("portal-key-1")`. Alternatively drop `kid` from the JWKS entirely — but keeping matching kids on both sides is the better demo of key rotation. Sources: https://github.com/spring-projects/spring-security/blob/main/oauth2/oauth2-jose/src/main/java/org/springframework/security/oauth2/jwt/NimbusJwtEncoder.java, https://github.com/spring-projects/spring-security/blob/main/oauth2/oauth2-jose/src/main/java/org/springframework/security/oauth2/jwt/JWKS.java

Minting per downstream call:

```java
Instant now = Instant.now();
JwtClaimsSet claims = JwtClaimsSet.builder()
        .issuer("https://portal.internal").audience(List.of("internal-services"))
        .subject(user.getUsername()).claim("tenant_id", tenantId).claim("roles", List.of("USER"))
        .issuedAt(now).expiresAt(now.plusSeconds(300)).build();
JwsHeader header = JwsHeader.with(SignatureAlgorithm.RS256).keyId("portal-key-1").type("JWT").build();
String token = enc.encode(JwtEncoderParameters.from(header, claims)).getTokenValue();
```

(`JwtEncoderParameters.from(JwsHeader, JwtClaimsSet)` and `encode(JwtEncoderParameters)` per the `NimbusJwtEncoder` javadoc above.) If the `JWKSource` holds more than one RSA key and the header names no `kid`, Security 7 throws `Failed to select a key since there are multiple for the signing algorithm [...]`; with one key it just uses it.

### Boot 3.x → Boot 4 / Security 6 → 7 differences that affect this code

| Item | Boot 3.x / Security 6 | Boot 4 / Security 7 | Effect |
|---|---|---|---|
| Starter | `spring-boot-starter-oauth2-resource-server` | `spring-boot-starter-security-oauth2-resource-server` (module `spring-boot-security-oauth2-resource-server`, package `org.springframework.boot.security.oauth2.server.resource.autoconfigure`). Old starter still published in 4.0.x but its POM says "deprecated in favor of spring-boot-starter-security-oauth2-resource-server". | Use the new name in `service-a`/`service-b` POMs. Source: https://github.com/spring-projects/spring-boot/wiki/Spring-Boot-4.0-Migration-Guide; local `~/.m2/.../spring-boot-starter-oauth2-resource-server/4.0.6/*.pom` |
| HTTP client for portal→service-a | `RestTemplate`/`RestClient` via web starter | Add `spring-boot-starter-restclient` explicitly ("developers should use `spring-boot-starter-restclient` for imperative REST calls") | Portal POM needs it to get `RestClient.Builder` auto-configured. Source: migration guide above |
| JSON | Jackson 2 | Jackson 3 (`tools.jackson` group). Nimbus JOSE has its own JSON handling, and `spring-security-oauth2-jose` does not use Jackson for JWT parsing. | No effect on JWT code; only matters if you serialize Security objects. Source: https://docs.spring.io/spring-security/reference/migration/index.html |
| `typ` validation | Opt-in via `validateTypes`/`JwtTypeValidator` | `JwtTypeValidator.jwt()` added by default; `validateTypes` default `false` | Header `typ: "JWT"` (which `mint-jwt.sh` and the `JwsHeader` above set) is accepted; omit `typ` and it is still accepted (validator allows absent `typ`). Source: https://docs.spring.io/spring-security/reference/migration/servlet/oauth2.html |
| `NimbusJwtEncoder` | Constructor with `JWKSource` only | Same constructor + `withKeyPair`/`withSecretKey` builders (7.0), `setJwkSelector` (6.5) | Either construction works; watch the thumbprint `kid` default on the builder. |
| `NimbusJwtDecoder` remote timeouts | 500 ms | 30 s | Irrelevant here (no remote JWKS). |
| Java baseline | 17 | 17 (Boot 4.0 "requires Java 17 or later") | Java 21 fine. |

Everything in `public-key-location` handling, `NimbusJwtDecoder.withPublicKey`, `JwtClaimValidator`, `@AuthenticationPrincipal Jwt` is unchanged between 6.x and 7.x.

---

## Summary / recommendations for `gen-keys.sh` and `mint-jwt.sh`

1. `gen-keys.sh`: `openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048` → `openssl pkey -pubout`; then the `pem-to-jwk.sh` body above with `kid=portal-key-1`. Emit `{"keys":[...]}` to paste into `RequestAuthentication.jwks` and the bare `BEGIN PUBLIC KEY` PEM for `public-key-location`. Works with OpenSSL 3 and LibreSSL.
2. `mint-jwt.sh`: the body above; use `-120` (not `-60`) for the expired token because Envoy allows 60 s skew. Forged token = same script with `other.key`.
3. `verify.sh` can reuse `verify-jwt.sh` to prove signatures offline with `openssl dgst -sha256 -verify` before touching the cluster.
4. JWKS: `alg`/`use` optional, `kid` matched only when present on both sides — keep `kid: portal-key-1` in both the JWKS and every token.
5. Spring: `spring-boot-starter-security-oauth2-resource-server`, `public-key-location` (SPKI PEM only), `audiences: internal-services`, `authorities-claim-name: roles`, `authority-prefix: ROLE_`; portal encoder must set `keyID("portal-key-1")`.

Status: complete
