package demo.servicea;

import java.util.Map;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.http.HttpHeaders;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;

@RestController
class HelloController {

  private static final ParameterizedTypeReference<Map<String, Object>> JSON = new ParameterizedTypeReference<>() {};

  private final RestClient serviceB;

  HelloController(RestClient.Builder builder, @Value("${service-a.downstream.service-b-url}") String serviceBUrl) {
    this.serviceB = builder.baseUrl(serviceBUrl).build();
  }

  @GetMapping("/healthz")
  Map<String, String> healthz() {
    return Map.of("status", "ok");
  }

  @GetMapping("/hello")
  Map<String, Object> hello(@AuthenticationPrincipal Jwt jwt) {
    authorize(jwt, "read:hello");
    // Forward the SAME Internal JWT unchanged: End-User Identity travels with the request; Service Identity is the mesh's job.
    Map<String, Object> downstream = serviceB.get().uri("/hello")
        .header(HttpHeaders.AUTHORIZATION, "Bearer " + jwt.getTokenValue())
        .retrieve()
        .body(JSON);
    return Map.of(
        "via", "service-a",
        "sub", jwt.getSubject(),
        "tenant_id", jwt.getClaimAsString("tenant_id"),
        "downstream", downstream);
  }

  // Authorization Decision Point: OPA/policy engine integration point; see README. Today it only asserts the Tenant claim is present.
  private void authorize(Jwt jwt, String action) {
    if (jwt.getClaimAsString("tenant_id") == null) {
      throw new AccessDeniedException("tenant_id claim required for " + action);
    }
  }
}
