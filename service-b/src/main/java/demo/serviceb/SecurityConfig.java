package demo.serviceb;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;

@Configuration
class SecurityConfig {

  @Bean
  SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
    return http
        .csrf(csrf -> csrf.disable()) // stateless bearer-token API; there is no browser session to protect
        .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
        .authorizeHttpRequests(auth -> auth
            .requestMatchers("/healthz").permitAll() // kubelet probes; the only unauthenticated path
            .requestMatchers("/hello").hasRole("USER")
            .anyRequest().denyAll())
        // defense in depth: the waypoint already verified the Internal JWT; the app verifies again with the same public key
        .oauth2ResourceServer(rs -> rs.jwt(Customizer.withDefaults()))
        .build();
  }
}
