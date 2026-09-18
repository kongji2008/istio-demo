package demo.portal;

import com.nimbusds.jose.jwk.JWK;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.source.ImmutableJWKSet;
import java.io.IOException;
import java.security.interfaces.RSAPrivateKey;
import java.security.interfaces.RSAPublicKey;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.io.Resource;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.converter.RsaKeyConverters;
import org.springframework.security.core.userdetails.User;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.jwt.NimbusJwtEncoder;
import org.springframework.security.provisioning.InMemoryUserDetailsManager;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.web.client.RestClient;

@Configuration
class SecurityConfig {

  @Bean
  SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
    return http
        // demo: login is driven by curl in verify.sh; CSRF is out of this demo's scope
        .csrf(csrf -> csrf.disable())
        .authorizeHttpRequests(auth -> auth
            .requestMatchers("/api/**").authenticated()
            .anyRequest().permitAll()) // default login page and /healthz
        .formLogin(Customizer.withDefaults())
        .build();
  }

  @Bean
  UserDetailsService users() {
    // demo users; {noop} selects the plaintext password encoder
    return new InMemoryUserDetailsManager(
        User.withUsername("alice").password("{noop}password").roles("USER").build(),
        User.withUsername("bob").password("{noop}password").roles("USER").build());
  }

  @Bean
  JwtEncoder jwtEncoder(@Value("${portal.jwt.private-key}") Resource privateKeyPem,
                        @Value("${portal.jwt.public-key}") Resource publicKeyPem) throws IOException {
    RSAPrivateKey priv = RsaKeyConverters.pkcs8().convert(privateKeyPem.getInputStream()); // PKCS#8 "BEGIN PRIVATE KEY"
    RSAPublicKey pub = RsaKeyConverters.x509().convert(publicKeyPem.getInputStream());     // SPKI "BEGIN PUBLIC KEY"
    // kid MUST match the JWKS in RequestAuthentication; Security 7's withKeyPair defaults kid to a thumbprint and the waypoint then 401s
    JWK jwk = new RSAKey.Builder(pub).privateKey(priv).keyID(TokenMinter.KEY_ID).build();
    return new NimbusJwtEncoder(new ImmutableJWKSet<>(new JWKSet(jwk)));
  }

  @Bean
  RestClient serviceAClient(RestClient.Builder builder,
                            @Value("${portal.downstream.service-a-url}") String serviceAUrl) {
    return builder.baseUrl(serviceAUrl).build();
  }
}
