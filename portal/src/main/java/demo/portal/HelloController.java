package demo.portal;

import java.util.Map;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.http.HttpHeaders;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;

@RestController
class HelloController {

  private static final ParameterizedTypeReference<Map<String, Object>> JSON = new ParameterizedTypeReference<>() {};

  private final TokenMinter minter;
  private final RestClient serviceA;

  HelloController(TokenMinter minter, RestClient serviceAClient) {
    this.minter = minter;
    this.serviceA = serviceAClient;
  }

  @GetMapping("/healthz")
  Map<String, String> healthz() {
    return Map.of("status", "ok");
  }

  @GetMapping("/api/hello")
  Map<String, Object> hello(Authentication authentication) {
    String user = authentication.getName();
    String token = minter.mint(user);
    // Only the Internal JWT travels downstream; the Browser Session cookie terminates here and is never forwarded.
    Map<String, Object> downstream = serviceA.get().uri("/hello")
        .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
        .retrieve()
        .body(JSON);
    return Map.of("via", "portal", "user", user, "downstream", downstream);
  }
}
