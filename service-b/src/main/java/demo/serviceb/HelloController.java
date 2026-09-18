package demo.serviceb;

import java.util.Map;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
class HelloController {

  @GetMapping("/healthz")
  Map<String, String> healthz() {
    return Map.of("status", "ok");
  }

  @GetMapping("/hello")
  Map<String, Object> hello(@AuthenticationPrincipal Jwt jwt) {
    authorize(jwt, "read:hello");
    // Claims are read straight from the verified Internal JWT: this is the in-app view of End-User Identity and Tenant.
    return Map.of(
        "via", "service-b",
        "greeting", "Hello, " + jwt.getSubject() + "!",
        "sub", jwt.getSubject(),
        "tenant_id", jwt.getClaimAsString("tenant_id"),
        "roles", jwt.getClaimAsStringList("roles"));
  }

  // Authorization Decision Point: OPA/policy engine integration point; see README. Today it only asserts the Tenant claim is present.
  private void authorize(Jwt jwt, String action) {
    if (jwt.getClaimAsString("tenant_id") == null) {
      throw new AccessDeniedException("tenant_id claim required for " + action);
    }
  }
}
