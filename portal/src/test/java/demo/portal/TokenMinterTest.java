package demo.portal;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.nimbusds.jose.jwk.JWK;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.source.ImmutableJWKSet;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.interfaces.RSAPublicKey;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.oauth2.jwt.NimbusJwtEncoder;

class TokenMinterTest {

  @Test
  void mintsRs256TokenWithPortalKidAndTenantClaim() throws Exception {
    KeyPairGenerator gen = KeyPairGenerator.getInstance("RSA");
    gen.initialize(2048);
    KeyPair kp = gen.generateKeyPair();
    RSAPublicKey pub = (RSAPublicKey) kp.getPublic();
    JWK jwk = new RSAKey.Builder(pub).privateKey(kp.getPrivate()).keyID(TokenMinter.KEY_ID).build();
    TokenMinter minter = new TokenMinter(new NimbusJwtEncoder(new ImmutableJWKSet<>(new JWKSet(jwk))));

    Jwt jwt = NimbusJwtDecoder.withPublicKey(pub).build().decode(minter.mint("alice"));

    // kid is what Envoy's jwt_authn matches against the JWKS in RequestAuthentication
    assertEquals("portal-key-1", jwt.getHeaders().get("kid"));
    assertEquals("https://portal.internal", jwt.getIssuer().toString());
    assertEquals(List.of("internal-services"), jwt.getAudience());
    assertEquals("alice", jwt.getSubject());
    assertEquals("tenant-001", jwt.getClaimAsString("tenant_id"));
    assertEquals(List.of("USER"), jwt.getClaimAsStringList("roles"));
  }
}
