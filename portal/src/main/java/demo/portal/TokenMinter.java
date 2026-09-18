package demo.portal;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import org.springframework.security.oauth2.jose.jws.SignatureAlgorithm;
import org.springframework.security.oauth2.jwt.JwsHeader;
import org.springframework.security.oauth2.jwt.JwtClaimsSet;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.jwt.JwtEncoderParameters;
import org.springframework.stereotype.Component;

/** Mints the Internal JWT that carries End-User Identity downstream. The only code that uses the Signing Key. */
@Component
class TokenMinter {

  static final String KEY_ID = "portal-key-1";
  static final String ISSUER = "https://portal.internal";
  static final String AUDIENCE = "internal-services";
  static final long TTL_SECONDS = 300;

  // InMemoryUserDetailsManager cannot carry tenant_id, so the Tenant lookup lives beside it instead of in a custom UserDetails class.
  static final Map<String, String> TENANTS = Map.of("alice", "tenant-001", "bob", "tenant-002");

  private final JwtEncoder encoder;

  TokenMinter(JwtEncoder encoder) {
    this.encoder = encoder;
  }

  String mint(String username) {
    Instant now = Instant.now();
    JwtClaimsSet claims = JwtClaimsSet.builder()
        .issuer(ISSUER)
        .audience(List.of(AUDIENCE))
        .subject(username)
        .claim("tenant_id", TENANTS.get(username))
        .claim("roles", List.of("USER"))
        .issuedAt(now)
        .expiresAt(now.plusSeconds(TTL_SECONDS)) // short-lived: a fresh token is minted per downstream call
        .build();
    // The header kid must equal the JWKS kid in RequestAuthentication, or the waypoint answers 401 "Jwks doesn't have key to match kid or alg from Jwt".
    JwsHeader header = JwsHeader.with(SignatureAlgorithm.RS256).keyId(KEY_ID).type("JWT").build();
    return encoder.encode(JwtEncoderParameters.from(header, claims)).getTokenValue();
  }
}
