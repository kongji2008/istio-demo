# Istio Ambient + Internal JWT Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A runnable kind cluster where Istio ambient owns service-to-service authn/authz (ztunnel L4 + waypoint L7) and a Spring Boot 4 portal mints an Internal JWT that carries End-User Identity down portal -> service-a -> service-b, proven by `scripts/verify.sh` passing all 10 scenarios.

**Architecture:** Three Spring Boot 4.1.1 services (portal, service-a, service-b) with zero mesh code, deployed into ambient-labelled namespaces with a Deny-All Baseline, per-hop L4 allows enforced by ztunnel and L7 (`targetRefs`) allows plus `RequestAuthentication` enforced by per-namespace waypoints. An Istio-managed Gateway API ingress in its own non-ambient namespace admits browser traffic. Shell scripts generate keys, build/load images, create the cluster, deploy, and verify.

**Tech Stack:** Kubernetes 1.35.8 (kind v0.33.0), Istio 1.31.0 ambient profile, Gateway API v1.6.0 experimental, Java 21, Spring Boot 4.1.1 / Spring Security 7.1.1, Maven 3.9.16, Docker via colima, openssl/jq/xxd.

**Spec:** [BUILD-BRIEF.md](../../../BUILD-BRIEF.md) (decision-complete brief). Vocabulary: [CONTEXT.md](../../../CONTEXT.md). Cited facts: `.scratch/istio-ambient-jwt-demo/research/*.md`.

## Global Constraints

- Every artifact (code, comments, YAML, scripts, README) is English.
- Every script pins `--context kind-istio-demo` via the exact guard in brief §6; never a bare `kubectl`. Developer's current context may be a real cluster.
- Zero mesh code in Java: no mTLS, certificates, SPIFFE, SA tokens. Service calls are plain HTTP to K8s DNS names.
- Java under 500 lines total across the three modules; no interfaces/factories/strategies; one-sentence "why" comment on non-obvious blocks and key config.
- Non-goals: no DB, no frontend framework, no OPA (named Authorization Decision Point hook only), no observability, no production key management.
- Pins: `kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0`, Istio `1.31.0`, Gateway API `v1.6.0` experimental (`kubectl apply --server-side`), Spring Boot `4.1.1`, Java 21 via `/usr/libexec/java_home -v 21`.
- Starters (verified on Maven Central 2026-09-17): `spring-boot-starter-webmvc` (the brief's `spring-boot-starter-web` is deprecated in 4.1.1), `spring-boot-starter-security`, `spring-boot-starter-restclient`, `spring-boot-starter-security-oauth2-resource-server`, `spring-security-oauth2-jose`.
- Images: `istio-demo/portal:dev`, `istio-demo/service-a:dev`, `istio-demo/service-b:dev`, `imagePullPolicy: IfNotPresent`.
- Key id everywhere: `portal-key-1`. Issuer `https://portal.internal`. Audience `internal-services`. Users `alice/password/tenant-001`, `bob/password/tenant-002`, role `USER`.
- Checkpoint commits: after (1) Maven build green, (2) `setup-cluster.sh` complete, (3) `deploy.sh` all pods Ready, (4) `verify.sh` 10/10 PASS.
- Do not edit `CONTEXT.md`, `docs/adr/`, `.scratch/`, `BUILD-BRIEF.md`.

---

## File structure

| Path | Responsibility |
|---|---|
| `pom.xml` | Aggregator + Boot parent, `java.version=21`, declares `spring-boot-maven-plugin` for fat jars |
| `portal/pom.xml`, `portal/Dockerfile`, `portal/src/main/resources/application.yaml`, `application-local.yaml` | Portal module wiring and config |
| `portal/src/main/java/demo/portal/PortalApplication.java` | main |
| `portal/src/main/java/demo/portal/SecurityConfig.java` | form login, users, `JwtEncoder` bean (kid pitfall), `RestClient` bean |
| `portal/src/main/java/demo/portal/TokenMinter.java` | mints the Internal JWT; holds `TENANTS` map |
| `portal/src/main/java/demo/portal/HelloController.java` | `/healthz`, `/api/hello` -> service-a |
| `portal/src/test/java/demo/portal/TokenMinterTest.java` | asserts kid/claims of minted token |
| `service-a/...` | resource server; `/hello` forwards token to service-b; Authorization Decision Point |
| `service-b/...` | resource server; `/hello` returns greeting; Authorization Decision Point |
| `k8s/00..90-*.yaml` | manifests as brief §3/§5 |
| `scripts/*.sh`, `scripts/kind-config.yaml` | brief §6 |
| `README.md` | brief §8 |
| `.gitignore` | `target/`, `keys/` |

---

### Task 1: Repository scaffold and Maven parent

**Files:**
- Create: `.gitignore`, `pom.xml`

**Interfaces:**
- Produces: Maven coordinates `demo:istio-demo:0.1.0` (pom) that Tasks 2–4 use as `<parent>` with `<relativePath>../pom.xml</relativePath>`.

- [x] **Step 1: git init and ignore file**

```bash
cd /path/to/istio-demo && git init -b main
cat > .gitignore <<'EOF'
target/
keys/
.DS_Store
EOF
```

- [x] **Step 2: Parent POM**

`pom.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>

  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>4.1.1</version>
    <relativePath/>
  </parent>

  <groupId>demo</groupId>
  <artifactId>istio-demo</artifactId>
  <version>0.1.0</version>
  <packaging>pom</packaging>
  <description>Istio ambient + Spring Boot internal JWT propagation demo</description>

  <properties>
    <java.version>21</java.version>
  </properties>

  <modules>
    <module>portal</module>
    <module>service-a</module>
    <module>service-b</module>
  </modules>

  <build>
    <plugins>
      <!-- repackage each module into a fat jar; the goal is a no-op on this pom-packaged parent -->
      <plugin>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-maven-plugin</artifactId>
      </plugin>
    </plugins>
  </build>
</project>
```

- [x] **Step 3: Commit scaffold**

```bash
git add .gitignore pom.xml BUILD-BRIEF.md CONTEXT.md docs .scratch .claude/settings.local.json
git commit -m "chore: scaffold repo, Maven parent, planning artifacts"
```

---

### Task 2: portal module

**Files:**
- Create: `portal/pom.xml`, `portal/Dockerfile`, `portal/src/main/resources/application.yaml`, `portal/src/main/resources/application-local.yaml`, `portal/src/main/java/demo/portal/{PortalApplication,SecurityConfig,TokenMinter,HelloController}.java`, `portal/src/test/java/demo/portal/TokenMinterTest.java`

**Interfaces:**
- Produces: `GET /api/hello` (session-authenticated) -> `{"via":"portal","user":<sub>,"downstream":<service-a JSON>}`; `GET /healthz` -> `{"status":"ok"}`; `POST /login` form fields `username`, `password`. Properties `portal.jwt.private-key`, `portal.jwt.public-key` (Resource locations), `portal.downstream.service-a-url`.
- Consumes: service-a `GET /hello` with `Authorization: Bearer`.

- [x] **Step 1: POM**

`portal/pom.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>demo</groupId>
    <artifactId>istio-demo</artifactId>
    <version>0.1.0</version>
    <relativePath>../pom.xml</relativePath>
  </parent>
  <artifactId>portal</artifactId>
  <description>Browser-facing Portal: form login, mints the Internal JWT, calls service-a</description>

  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-webmvc</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-security</artifactId>
    </dependency>
    <!-- Boot 4: RestClient.Builder auto-config lives in its own starter -->
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-restclient</artifactId>
    </dependency>
    <!-- NimbusJwtEncoder -->
    <dependency>
      <groupId>org.springframework.security</groupId>
      <artifactId>spring-security-oauth2-jose</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-test</artifactId>
      <scope>test</scope>
    </dependency>
  </dependencies>
</project>
```

- [x] **Step 2: Dockerfile**

`portal/Dockerfile` (identical in the other two modules):
```dockerfile
FROM eclipse-temurin:21-jre
COPY target/*.jar /app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app.jar"]
```

- [x] **Step 3: application.yaml + local profile**

`portal/src/main/resources/application.yaml`:
```yaml
server:
  port: 8080

portal:
  jwt:
    # Signing Key mounted from Secret portal-signing-key; never inline key material
    private-key: file:/etc/portal-keys/private.pem
    public-key: file:/etc/portal-keys/public.pem
  downstream:
    # plain HTTP to the K8s DNS name; ztunnel adds mTLS, the waypoint checks the Internal JWT
    service-a-url: http://service-a.svc-a-ns.svc.cluster.local:8080
```

`portal/src/main/resources/application-local.yaml` (for `mvn spring-boot:run -Dspring-boot.run.profiles=local`, cwd = module dir):
```yaml
portal:
  jwt:
    private-key: file:../keys/portal.key
    public-key: file:../keys/portal.pub
  downstream:
    service-a-url: http://localhost:8081
```

- [x] **Step 4: Write the failing test**

`portal/src/test/java/demo/portal/TokenMinterTest.java`:
```java
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
```

- [x] **Step 5: Run test to verify it fails**

Run: `export JAVA_HOME=$(/usr/libexec/java_home -v 21); mvn -q -pl portal test`
Expected: compilation FAIL, `TokenMinter` not found.

- [x] **Step 6: Implement main, TokenMinter, SecurityConfig, HelloController**

`portal/src/main/java/demo/portal/PortalApplication.java`:
```java
package demo.portal;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class PortalApplication {
  public static void main(String[] args) {
    SpringApplication.run(PortalApplication.class, args);
  }
}
```

`portal/src/main/java/demo/portal/TokenMinter.java`:
```java
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
```

`portal/src/main/java/demo/portal/SecurityConfig.java`:
```java
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
```

`portal/src/main/java/demo/portal/HelloController.java`:
```java
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
```

- [x] **Step 7: Run test to verify it passes**

Run: `mvn -q -pl portal test`
Expected: `BUILD SUCCESS`, 1 test passed.

---

### Task 3: service-a module

**Files:**
- Create: `service-a/pom.xml`, `service-a/Dockerfile`, `service-a/src/main/resources/application.yaml`, `application-local.yaml`, `service-a/src/main/java/demo/servicea/{ServiceAApplication,SecurityConfig,HelloController}.java`

**Interfaces:**
- Produces: `GET /hello` (Bearer, `ROLE_USER`) -> `{"via":"service-a","sub":..,"tenant_id":..,"downstream":<service-b JSON>}`; `GET /healthz`. Property `service-a.downstream.service-b-url`.
- Consumes: service-b `GET /hello`.

- [x] **Step 1: POM**

`service-a/pom.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>demo</groupId>
    <artifactId>istio-demo</artifactId>
    <version>0.1.0</version>
    <relativePath>../pom.xml</relativePath>
  </parent>
  <artifactId>service-a</artifactId>
  <description>Intermediate resource server: verifies the Internal JWT and forwards it to service-b</description>

  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-webmvc</artifactId>
    </dependency>
    <!-- Boot 4 name; the old spring-boot-starter-oauth2-resource-server is deprecated -->
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-security-oauth2-resource-server</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-restclient</artifactId>
    </dependency>
  </dependencies>
</project>
```

- [x] **Step 2: Dockerfile** — same four lines as Task 2 Step 2.

- [x] **Step 3: application.yaml + local profile**

`service-a/src/main/resources/application.yaml`:
```yaml
server:
  port: 8080

service-a:
  downstream:
    service-b-url: http://service-b.svc-b-ns.svc.cluster.local:8080

spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          # SPKI PEM only; PKCS#1 "BEGIN RSA PUBLIC KEY" will not parse
          public-key-location: file:/etc/portal-keys/public.pem
          # adds the aud validator; issuer-uri must NOT be set (Boot would attempt OIDC discovery). iss is enforced by the waypoint.
          audiences: internal-services
          # roles: ["USER"] -> ROLE_USER with no code
          authorities-claim-name: roles
          authority-prefix: ROLE_
```

`service-a/src/main/resources/application-local.yaml`:
```yaml
server:
  port: 8081
service-a:
  downstream:
    service-b-url: http://localhost:8082
spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          public-key-location: file:../keys/portal.pub
```

- [x] **Step 4: Java**

`service-a/src/main/java/demo/servicea/ServiceAApplication.java`:
```java
package demo.servicea;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class ServiceAApplication {
  public static void main(String[] args) {
    SpringApplication.run(ServiceAApplication.class, args);
  }
}
```

`service-a/src/main/java/demo/servicea/SecurityConfig.java`:
```java
package demo.servicea;

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
```

`service-a/src/main/java/demo/servicea/HelloController.java`:
```java
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
```

- [x] **Step 5: Compile**

Run: `mvn -q -pl service-a -DskipTests package`
Expected: `BUILD SUCCESS`, `service-a/target/service-a-0.1.0.jar` exists.

---

### Task 4: service-b module

**Files:**
- Create: `service-b/pom.xml`, `service-b/Dockerfile`, `service-b/src/main/resources/application.yaml`, `application-local.yaml`, `service-b/src/main/java/demo/serviceb/{ServiceBApplication,SecurityConfig,HelloController}.java`

**Interfaces:**
- Produces: `GET /hello` -> `{"via":"service-b","greeting":"Hello, <sub>!","sub":..,"tenant_id":..,"roles":[..]}`; `GET /healthz`.

- [x] **Step 1: POM** — as Task 3 Step 1 with `<artifactId>service-b</artifactId>`, description "Terminal resource server: verifies the Internal JWT and returns a greeting", and **without** the `spring-boot-starter-restclient` dependency.

- [x] **Step 2: Dockerfile** — same four lines as Task 2 Step 2.

- [x] **Step 3: application.yaml** — as Task 3 Step 3 without the `service-a:` block. `application-local.yaml`:
```yaml
server:
  port: 8082
spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          public-key-location: file:../keys/portal.pub
```

- [x] **Step 4: Java**

`ServiceBApplication.java`: as Task 3 with package `demo.serviceb`, class `ServiceBApplication`.

`SecurityConfig.java`: identical to Task 3 Step 4 with package `demo.serviceb`.

`service-b/src/main/java/demo/serviceb/HelloController.java`:
```java
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
```

- [x] **Step 5: Full build — CHECKPOINT 1**

Run:
```bash
export JAVA_HOME=$(/usr/libexec/java_home -v 21); mvn -q package
find . -name '*.java' -path '*/src/main/*' | xargs wc -l | tail -1
ls portal/target/*.jar service-a/target/*.jar service-b/target/*.jar
```
Expected: `BUILD SUCCESS`; total main-source line count < 500; three fat jars.

- [x] **Step 6: Commit checkpoint 1**

```bash
git add pom.xml portal service-a service-b
git commit -m "feat: portal, service-a, service-b on Spring Boot 4.1.1 (checkpoint 1: Maven green)"
```

---

### Task 5: Key generation and JWT minting scripts (+ generated manifests 32/60)

**Files:**
- Create: `scripts/gen-keys.sh`, `scripts/mint-jwt.sh`; generates `k8s/32-request-authentication.yaml`, `k8s/60-secrets.yaml`, `keys/{portal.key,portal.pub,other.key}`

**Interfaces:**
- Produces: `scripts/mint-jwt.sh <private.pem> [ttl] [kid] [sub] [tenant]` prints a compact JWS. `k8s/60-secrets.yaml` defines Secret `portal-signing-key` (portal-ns; keys `private.pem`, `public.pem`) and ConfigMaps `portal-public-key` (svc-a-ns, svc-b-ns; key `public.pem`), which Tasks 6 mounts. `k8s/32-request-authentication.yaml` defines `RequestAuthentication` `portal-jwt` in svc-a-ns and svc-b-ns.

- [x] **Step 1: gen-keys.sh**

`scripts/gen-keys.sh`:
```bash
#!/usr/bin/env bash
# Generates the demo Signing Key pair (keys/portal.key, keys/portal.pub), a second key for the
# forged-token scenario (keys/other.key), and writes the two manifests that carry key material:
# k8s/60-secrets.yaml (Secret + public-key ConfigMaps) and k8s/32-request-authentication.yaml (inline JWKS).
# Re-running keeps existing keys; delete keys/ to rotate. Needs openssl, xxd, base64, jq (all present on macOS).
set -euo pipefail
cd "$(dirname "$0")/.."
KID=portal-key-1
mkdir -p keys
[ -f keys/portal.key ] || openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out keys/portal.key   # PKCS#8 "BEGIN PRIVATE KEY"
openssl pkey -in keys/portal.key -pubout -out keys/portal.pub                                                  # SPKI "BEGIN PUBLIC KEY"
[ -f keys/other.key ] || openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out keys/other.key     # for the forged-token test

# --- PEM -> JWK (research 04 §1). base64url per RFC 7515 App. C; no `base64 -w0` (macOS). ---
b64url() { base64 | tr -d '\n=' | tr '+/' '-_'; }
# `-modulus` prints the big-endian hex magnitude with NO leading 00 sign byte, which is exactly what JWK `n` needs.
MOD_HEX=$(openssl rsa -pubin -in keys/portal.pub -noout -modulus | sed 's/^Modulus=//')
N=$(printf '%s' "$MOD_HEX" | xxd -r -p | b64url)
EXP_DEC=$(openssl rsa -pubin -in keys/portal.pub -noout -text | sed -n 's/^Exponent: \([0-9]*\).*/\1/p')
EXP_HEX=$(printf '%x' "$EXP_DEC")
case $(( ${#EXP_HEX} % 2 )) in 1) EXP_HEX="0$EXP_HEX";; esac   # xxd needs whole bytes
E=$(printf '%s' "$EXP_HEX" | xxd -r -p | b64url)
JWKS=$(jq -cn --arg kid "$KID" --arg n "$N" --arg e "$E" \
  '{keys:[{kty:"RSA",use:"sig",alg:"RS256",kid:$kid,n:$n,e:$e}]}')

indent4() { sed 's/^/    /'; }
PRIV_PEM=$(indent4 < keys/portal.key)
PUB_PEM=$(indent4 < keys/portal.pub)

cat > k8s/60-secrets.yaml <<EOF
# DEMO ONLY: private key committed for reproducibility. Never do this in production.
# GENERATED by scripts/gen-keys.sh; do not edit by hand.
apiVersion: v1
kind: Secret
metadata:
  name: portal-signing-key
  namespace: portal-ns
type: Opaque
stringData:
  private.pem: |
$PRIV_PEM
  public.pem: |
$PUB_PEM
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: portal-public-key
  namespace: svc-a-ns
data:
  public.pem: |
$PUB_PEM
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: portal-public-key
  namespace: svc-b-ns
data:
  public.pem: |
$PUB_PEM
EOF

request_authentication() { # ns service
cat <<EOF
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: portal-jwt
  namespace: $1
spec:
  # Waypoint-attached: waypoints ignore selector-based policies. One RequestAuthentication per enrolled Service.
  targetRefs:
    - group: ""
      kind: Service
      name: $2
  jwtRules:
    - issuer: "https://portal.internal"
      audiences: ["internal-services"]
      # REQUIRED: the default strips the token and the in-app resource server would 401 on the happy path
      forwardOriginalToken: true
      # Inline JWKS (ADR-0003): no istiod fetch, so the portal-ns Deny-All Baseline cannot break verification.
      jwks: |
        $JWKS
EOF
}
{
  echo "# GENERATED by scripts/gen-keys.sh (run it again after rotating keys); do not edit by hand."
  echo "# A request with no token passes this filter unauthenticated and is then denied by the requestPrincipals rule (403, not 401)."
  request_authentication svc-a-ns service-a
  echo "---"
  request_authentication svc-b-ns service-b
} > k8s/32-request-authentication.yaml

echo "wrote keys/, k8s/60-secrets.yaml, k8s/32-request-authentication.yaml (kid=$KID)"
```

- [x] **Step 2: mint-jwt.sh**

`scripts/mint-jwt.sh`:
```bash
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
```

- [x] **Step 3: Run and verify offline**

```bash
chmod +x scripts/*.sh && scripts/gen-keys.sh
head -3 keys/portal.key keys/portal.pub
jq -r '.' <<<"$(grep -o '{"keys".*}' k8s/32-request-authentication.yaml | head -1)" | head -5
TOK=$(scripts/mint-jwt.sh keys/portal.key 300); echo "$TOK" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq .
```
Expected: `BEGIN PRIVATE KEY` / `BEGIN PUBLIC KEY`; JWKS with `kid: portal-key-1`, `e: AQAB`; payload with `iss`, `aud`, `sub: alice`, `tenant_id: tenant-001`, `roles`.

---

### Task 6: Kubernetes manifests (namespaces, workloads, policies, waypoints, gateway, test pods)

**Files:**
- Create: `k8s/00-namespaces.yaml`, `k8s/10-portal.yaml`, `k8s/11-service-a.yaml`, `k8s/12-service-b.yaml`, `k8s/20-peer-authentication.yaml`, `k8s/30-deny-all.yaml`, `k8s/31-authorization-policies.yaml`, `k8s/40-waypoints.yaml`, `k8s/50-gateway.yaml`, `k8s/90-test-pods.yaml`

**Interfaces:**
- Consumes: Secret/ConfigMaps from Task 5; images from Task 7.
- Produces: SA names `portal-sa`, `svc-a-sa`, `svc-b-sa`, `waypoint`, `demo-gateway-istio`; Services `portal`, `service-a`, `service-b` on 8080; test pods `curl` (rogue-ns), `curl` (default), `curl-as-svc-a` (svc-a-ns).

- [x] **Step 1: 00-namespaces.yaml**

```yaml
# Namespaces. istio-ingress is deliberately NOT ambient: the Istio-managed gateway speaks HBONE natively (ADR-0002).
apiVersion: v1
kind: Namespace
metadata:
  name: istio-ingress
  labels:
    istio.io/dataplane-mode: none
---
apiVersion: v1
kind: Namespace
metadata:
  name: portal-ns
  labels:
    istio.io/dataplane-mode: ambient
---
apiVersion: v1
kind: Namespace
metadata:
  name: svc-a-ns
  labels:
    istio.io/dataplane-mode: ambient
    # what `istioctl waypoint apply --enroll-namespace` would set; routes in-mesh traffic for this ns through Gateway "waypoint"
    istio.io/use-waypoint: waypoint
---
apiVersion: v1
kind: Namespace
metadata:
  name: svc-b-ns
  labels:
    istio.io/dataplane-mode: ambient
    istio.io/use-waypoint: waypoint
---
# In-mesh client with the wrong Service Identity (verify.sh scenario 2a). No allow rule anywhere names its SA.
apiVersion: v1
kind: Namespace
metadata:
  name: rogue-ns
  labels:
    istio.io/dataplane-mode: ambient
```

- [x] **Step 2: 10-portal.yaml**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: portal-sa
  namespace: portal-ns
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: portal
  namespace: portal-ns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: portal
  template:
    metadata:
      labels:
        app: portal
    spec:
      # Service Identity cluster.local/ns/portal-ns/sa/portal-sa comes from this SA via ztunnel; no code involved
      serviceAccountName: portal-sa
      containers:
        - name: portal
          image: istio-demo/portal:dev
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 5
            failureThreshold: 12
          volumeMounts:
            - name: signing-key
              mountPath: /etc/portal-keys
              readOnly: true
      volumes:
        - name: signing-key
          secret:
            secretName: portal-signing-key
---
apiVersion: v1
kind: Service
metadata:
  name: portal
  namespace: portal-ns
spec:
  selector:
    app: portal
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      appProtocol: http
```

- [x] **Step 3: 11-service-a.yaml and 12-service-b.yaml**

Same shape as Step 2 with: SA `svc-a-sa` / `svc-b-sa`; Deployment+Service `service-a` / `service-b` in `svc-a-ns` / `svc-b-ns`; image `istio-demo/service-a:dev` / `istio-demo/service-b:dev`; volume:
```yaml
          volumeMounts:
            - name: portal-public-key
              mountPath: /etc/portal-keys
              readOnly: true
      volumes:
        - name: portal-public-key
          configMap:
            name: portal-public-key
```
Service ports block identical (`appProtocol: http` helps the waypoint treat it as HTTP).

- [x] **Step 4: 20-peer-authentication.yaml**

```yaml
# STRICT mTLS per application namespace, enforced by ztunnel. Namespace scope is sufficient; mesh-wide is not required.
# Plaintext from outside the mesh is closed at L4 with no HTTP response (verify.sh scenario 2b).
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: strict-mtls
  namespace: portal-ns
spec:
  mtls:
    mode: STRICT
---
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: strict-mtls
  namespace: svc-a-ns
spec:
  mtls:
    mode: STRICT
---
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: strict-mtls
  namespace: svc-b-ns
spec:
  mtls:
    mode: STRICT
---
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: strict-mtls
  namespace: rogue-ns
spec:
  mtls:
    mode: STRICT
```

- [x] **Step 5: 30-deny-all.yaml**

```yaml
# Deny-All Baseline: an empty-spec AuthorizationPolicy selects every captured workload in its namespace.
# Enforced by ztunnel only; waypoints ignore policies without targetRefs, hence the two waypoint-scoped policies below.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: portal-ns
spec: {}
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: svc-a-ns
spec: {}
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: svc-b-ns
spec: {}
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: rogue-ns
spec: {}
---
# Waypoint-scoped allow-nothing: gives the waypoint a default-deny too, without a mesh-wide policy in istio-system.
# ALLOW with no rules matches nothing; any Service enrolled later without its own allow is denied rather than allowed.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: waypoint-allow-nothing
  namespace: svc-a-ns
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: waypoint
  action: ALLOW
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: waypoint-allow-nothing
  namespace: svc-b-ns
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: waypoint
  action: ALLOW
```

- [x] **Step 6: 31-authorization-policies.yaml**

```yaml
# Per-hop allows. Ground truth is the per-hop identity table in BUILD-BRIEF.md §2 / research 03.
# L4 fields on a selector/no-targetRefs policy are evaluated by ztunnel; L7 fields there fail safe to DENY, hence targetRefs for anything L7.
# The waypoint does not impersonate the caller, so the destination ztunnel sees the waypoint's SA, not portal-sa / svc-a-sa.

# gateway -> portal pod (ztunnel L4)
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-gw-to-portal
  namespace: portal-ns
spec:
  action: ALLOW
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/istio-ingress/sa/demo-gateway-istio"]
---
# svc-a waypoint -> service-a pod (ztunnel L4). Do NOT list portal-sa here: ztunnel never sees it once the waypoint is in the path,
# and leaving it out is what makes the waypoint mandatory.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-waypoint-to-a
  namespace: svc-a-ns
spec:
  action: ALLOW
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/svc-a-ns/sa/waypoint"]
---
# portal -> service-a, evaluated by the svc-a waypoint (L7): Service Identity + Request Principal + method/path
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-portal-to-a
  namespace: svc-a-ns
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: service-a
  action: ALLOW
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/portal-ns/sa/portal-sa"]
            # <iss>/<sub> of a JWT verified by RequestAuthentication; any Portal-minted user
            requestPrincipals: ["https://portal.internal/*"]
      to:
        - operation:
            methods: ["GET"]
            paths: ["/hello"]
---
# svc-b waypoint -> service-b pod (ztunnel L4)
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-waypoint-to-b
  namespace: svc-b-ns
spec:
  action: ALLOW
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/svc-b-ns/sa/waypoint"]
---
# service-a -> service-b, evaluated by the svc-b waypoint (L7)
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-a-to-b
  namespace: svc-b-ns
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: service-b
  action: ALLOW
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/svc-a-ns/sa/svc-a-sa"]
            requestPrincipals: ["https://portal.internal/*"]
      to:
        - operation:
            methods: ["GET"]
            paths: ["/hello"]
```

- [x] **Step 7: 40-waypoints.yaml** (verbatim `istioctl waypoint generate --for service` output; the SA is named after the Gateway, so `waypoint` is what the L4 policies depend on)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  labels:
    istio.io/waypoint-for: service
  name: waypoint
  namespace: svc-a-ns
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  labels:
    istio.io/waypoint-for: service
  name: waypoint
  namespace: svc-b-ns
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
```

- [x] **Step 8: 50-gateway.yaml**

```yaml
# Ingress Gateway in its own non-ambient namespace (ADR-0002). Istio creates Deployment/Service/SA "demo-gateway-istio".
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: demo-gateway
  namespace: istio-ingress
  annotations:
    # kind has no LoadBalancer; NodePort + the kind extraPortMapping (30080 -> host 8080) serves the browser demo
    networking.istio.io/service-type: NodePort
spec:
  gatewayClassName: istio
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
---
# Same-name Service pre-created so Istio's server-side apply merges onto it and the nodePort stays pinned to 30080.
apiVersion: v1
kind: Service
metadata:
  name: demo-gateway-istio
  namespace: istio-ingress
spec:
  type: NodePort
  ports:
    - name: http
      port: 80
      protocol: TCP
      nodePort: 30080
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: portal
  namespace: portal-ns
spec:
  parentRefs:
    - name: demo-gateway
      namespace: istio-ingress
  rules:
    - backendRefs:
        - name: portal
          port: 8080
```
(If Istio refuses to merge onto the pre-created Service, delete that Service block and rely on port-forward; verify.sh port-forwards regardless.)

- [x] **Step 9: 90-test-pods.yaml**

```yaml
# Long-running curl pods for verify.sh. Committed rather than `kubectl run` so the run is deterministic and repeatable.
# Pods created after the namespace label are captured by ztunnel from their first packet.
apiVersion: v1
kind: Pod
metadata:
  name: curl
  namespace: rogue-ns  # in mesh, wrong Service Identity -> waypoint answers 403 (scenario 2a)
spec:
  containers:
    - name: curl
      image: curlimages/curl
      command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: curl
  namespace: default   # NOT in mesh: plaintext is closed by ztunnel at L4, no HTTP response (scenario 2b)
spec:
  containers:
    - name: curl
      image: curlimages/curl
      command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: curl-as-svc-a
  namespace: svc-a-ns  # right Service Identity for service-b; JWT scenarios 3-7
spec:
  serviceAccountName: svc-a-sa
  containers:
    - name: curl
      image: curlimages/curl
      command: ["sleep", "infinity"]
```

- [x] **Step 10: Static validation**

Run: `for f in k8s/*.yaml; do python3 -c "import sys,yaml; list(yaml.safe_load_all(open('$f')))" && echo "ok $f"; done` (or `kubectl --context kind-istio-demo apply --dry-run=client` after Task 8).
Expected: every file parses.

---

### Task 7: Cluster and build scripts

**Files:**
- Create: `scripts/kind-config.yaml`, `scripts/setup-cluster.sh`, `scripts/build-and-load.sh`, `scripts/deploy.sh`

**Interfaces:**
- Produces: kind cluster `istio-demo` (context `kind-istio-demo`) with Istio 1.31.0 ambient + Gateway API v1.6.0; images loaded; all manifests applied and Ready.

- [x] **Step 1: kind-config.yaml**

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      # NodePort 30080 of the ingress gateway Service -> http://localhost:8080 on the host for the browser demo
      - containerPort: 30080
        hostPort: 8080
        protocol: TCP
```

- [x] **Step 2: setup-cluster.sh**

```bash
#!/usr/bin/env bash
# Creates the kind cluster (Kubernetes 1.35.8) and installs Gateway API v1.6.0 + Istio 1.31.0 ambient profile.
set -euo pipefail
KIND_CLUSTER=istio-demo
KCTX="--context kind-${KIND_CLUSTER}"
# Guard: the developer's kubeconfig may point at real clusters. This script only ever creates and talks to the kind cluster.
kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER" \
  && { echo "FATAL: kind cluster ${KIND_CLUSTER} already exists; run 'kind delete cluster --name ${KIND_CLUSTER}' first" >&2; exit 1; }
cd "$(dirname "$0")/.."

# kind v0.33.0 defaults to Kubernetes 1.37, which Istio 1.31 does not support: always pass --image.
KIND_NODE_IMAGE="kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0"
ISTIO_VERSION=1.31.0
GATEWAY_API_VERSION=v1.6.0

istioctl version --remote=false | grep -q "$ISTIO_VERSION" \
  || { echo "FATAL: need istioctl ${ISTIO_VERSION} (curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -)" >&2; exit 1; }

kind create cluster --name "$KIND_CLUSTER" --image "$KIND_NODE_IMAGE" --config scripts/kind-config.yaml
kubectl() { command kubectl $KCTX "$@"; }   # every later kubectl call in this script is pinned

# Gateway API CRDs, experimental channel, server-side apply: exactly as the Istio 1.31 ambient docs do.
kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 \
  || kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"

# Ambient profile installs istiod, istio-cni and ztunnel; no ingress gateway component (the Gateway API creates ours). kind needs no platform flag.
istioctl install $KCTX --set profile=ambient --skip-confirmation

kubectl -n istio-system rollout status deploy/istiod --timeout=300s
kubectl -n istio-system rollout status ds/ztunnel --timeout=300s
kubectl -n istio-system rollout status ds/istio-cni-node --timeout=300s
kubectl get pods -n istio-system
echo "cluster ${KIND_CLUSTER} ready (context kind-${KIND_CLUSTER})"
```

- [x] **Step 3: build-and-load.sh**

```bash
#!/usr/bin/env bash
# Builds the three fat jars with Maven, builds the three images, and loads them into the kind cluster.
set -euo pipefail
KIND_CLUSTER=istio-demo
KCTX="--context kind-${KIND_CLUSTER}"
# Guard: the developer's kubeconfig may point at real clusters. Never run without the kind context.
kubectl $KCTX config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null | grep -qx "kind-${KIND_CLUSTER}" \
  || { echo "FATAL: kube context kind-${KIND_CLUSTER} not found; run scripts/setup-cluster.sh first" >&2; exit 1; }
kubectl() { command kubectl $KCTX "$@"; }   # every later kubectl call in this script is pinned
cd "$(dirname "$0")/.."

# The `java` on PATH is a broken jenv shim; pin JDK 21 explicitly.
export JAVA_HOME; JAVA_HOME=$(/usr/libexec/java_home -v 21)
mvn -q -DskipTests package

for svc in portal service-a service-b; do
  docker build -q -t "istio-demo/${svc}:dev" "$svc"
done
kind load docker-image --name "$KIND_CLUSTER" istio-demo/portal:dev istio-demo/service-a:dev istio-demo/service-b:dev
echo "images built and loaded into kind-${KIND_CLUSTER}"
```

- [x] **Step 4: deploy.sh**

```bash
#!/usr/bin/env bash
# Applies k8s/ in filename order and waits for the gateway, waypoints, apps and test pods to be Ready.
set -euo pipefail
KIND_CLUSTER=istio-demo
KCTX="--context kind-${KIND_CLUSTER}"
# Guard: the developer's kubeconfig may point at real clusters. Never run without the kind context.
kubectl $KCTX config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null | grep -qx "kind-${KIND_CLUSTER}" \
  || { echo "FATAL: kube context kind-${KIND_CLUSTER} not found; run scripts/setup-cluster.sh first" >&2; exit 1; }
kubectl() { command kubectl $KCTX "$@"; }   # every later kubectl call in this script is pinned
cd "$(dirname "$0")/.."

[ -f k8s/60-secrets.yaml ] || { echo "FATAL: k8s/60-secrets.yaml missing; run scripts/gen-keys.sh" >&2; exit 1; }
kubectl apply -f k8s/   # kubectl applies a directory in filename order: 00-namespaces first

# Istio provisions the gateway and waypoint Deployments asynchronously: wait for them to exist, then to roll out.
wait_deploy() {
  local ns=$1 name=$2
  for _ in $(seq 1 60); do kubectl -n "$ns" get deploy "$name" >/dev/null 2>&1 && break; sleep 2; done
  kubectl -n "$ns" rollout status "deploy/$name" --timeout=300s
}
wait_deploy istio-ingress demo-gateway-istio
wait_deploy svc-a-ns waypoint
wait_deploy svc-b-ns waypoint
wait_deploy portal-ns portal
wait_deploy svc-a-ns service-a
wait_deploy svc-b-ns service-b
kubectl -n rogue-ns wait --for=condition=Ready pod/curl --timeout=120s
kubectl -n default  wait --for=condition=Ready pod/curl --timeout=120s
kubectl -n svc-a-ns wait --for=condition=Ready pod/curl-as-svc-a --timeout=120s

kubectl get pods -A -l 'app in (portal,service-a,service-b)' -o wide
kubectl get gateway -A
kubectl get authorizationpolicies -A
echo "deployed; browser: http://localhost:8080/  (or: kubectl $KCTX -n istio-ingress port-forward svc/demo-gateway-istio 18080:80)"
```

- [x] **Step 5: Shell syntax check**

Run: `chmod +x scripts/*.sh && for s in scripts/*.sh; do bash -n "$s" && echo "ok $s"; done`
Expected: all ok.

---

### Task 8: CHECKPOINT 2 — create the cluster

- [x] **Step 1: Run setup**

Run: `scripts/setup-cluster.sh` (timeout 10 min).
Expected: kind cluster created from the 1.35.8 image; Gateway API CRDs applied; `istioctl install` prints installation complete; istiod, ztunnel, istio-cni-node rolled out.

- [x] **Step 2: Sanity**

```bash
kubectl --context kind-istio-demo version | grep Server
kubectl --context kind-istio-demo get gatewayclass
kubectl config current-context   # must still be the developer's original context, not kind
```
Expected: Server v1.35.8; `istio` and `istio-waypoint` GatewayClasses accepted; current-context unchanged.

- [x] **Step 3: Commit checkpoint 2**

```bash
git add scripts k8s
git commit -m "feat: k8s manifests, key/cluster/deploy scripts (checkpoint 2: cluster up)"
```

---

### Task 9: CHECKPOINT 3 — build, load, deploy

- [x] **Step 1: Build and load**

Run: `scripts/build-and-load.sh`
Expected: three `istio-demo/*:dev` images loaded; `docker exec istio-demo-control-plane crictl images | grep istio-demo` lists three.

- [x] **Step 2: Deploy**

Run: `scripts/deploy.sh` (timeout 10 min).
Expected: all `wait`/`rollout status` succeed; `get authorizationpolicies -A` lists 4 deny-all, 2 waypoint-allow-nothing, 5 allow-*.

- [x] **Step 3: Diagnose if a pod is not Ready**

```bash
kubectl --context kind-istio-demo -n portal-ns logs deploy/portal --tail=50
kubectl --context kind-istio-demo -n svc-a-ns describe pod -l app=service-a | tail -20
kubectl --context kind-istio-demo -n istio-system logs ds/ztunnel --tail=50
```
Check first: ambient labels present (`kubectl get ns --show-labels`), pod annotation `ambient.istio.io/redirection: enabled`, waypoint Gateway `Programmed=True`.

- [x] **Step 4: Check NodePort mapping**

Run: `kubectl --context kind-istio-demo -n istio-ingress get svc demo-gateway-istio -o jsonpath='{.spec.type} {.spec.ports[*].nodePort}'; curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/login`
Expected: `NodePort 30080` and HTTP 200. If the nodePort is not 30080, remove the pre-created Service from `50-gateway.yaml`, re-apply, and document port-forward as the only path.

- [x] **Step 5: Commit checkpoint 3**

```bash
git add -A k8s scripts
git commit -m "feat: deploy to kind (checkpoint 3: all pods Ready)"
```

---

### Task 10: verify.sh — CHECKPOINT 4

**Files:**
- Create: `scripts/verify.sh`

- [x] **Step 1: Write verify.sh**

```bash
#!/usr/bin/env bash
# Runs the 10 demo scenarios (BUILD-BRIEF.md §7) against the kind cluster. Prints PASS/FAIL per scenario, exits non-zero on any FAIL.
set -euo pipefail
KIND_CLUSTER=istio-demo
KCTX="--context kind-${KIND_CLUSTER}"
# Guard: the developer's kubeconfig may point at real clusters. Never run without the kind context.
kubectl $KCTX config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null | grep -qx "kind-${KIND_CLUSTER}" \
  || { echo "FATAL: kube context kind-${KIND_CLUSTER} not found; run scripts/setup-cluster.sh first" >&2; exit 1; }
kubectl() { command kubectl $KCTX "$@"; }   # every later kubectl call in this script is pinned
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
report() { # <name> <0|1> <detail>
  if [ "$2" = 0 ]; then printf 'PASS  %-40s %s\n' "$1" "$3"; PASS=$((PASS+1)); else printf 'FAIL  %-40s %s\n' "$1" "$3"; FAIL=$((FAIL+1)); fi
}
TMP=$(mktemp -d)
PF_PID=""
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

# --- keys: scenarios 4-7 need the Signing Key, scenario 6 a foreign key. On a fresh clone recover/generate them. ---
mkdir -p keys
[ -f keys/portal.key ] || kubectl -n portal-ns get secret portal-signing-key -o jsonpath='{.data.private\.pem}' | base64 -d > keys/portal.key
[ -f keys/other.key ]  || openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out keys/other.key 2>/dev/null
VALID=$(scripts/mint-jwt.sh keys/portal.key 300)
EXPIRED=$(scripts/mint-jwt.sh keys/portal.key -120)   # -120: Envoy allows 60 s clock skew
FORGED=$(scripts/mint-jwt.sh keys/other.key 300)      # right kid and claims, wrong key

# --- helpers ---
# incurl <ns> <pod> <curl args...>: runs curl in the pod; output = body, then "__CODE__<http_code>", then "__RC__<curl exit>"
incurl() {
  local ns=$1 pod=$2; shift 2
  kubectl -n "$ns" exec "$pod" -- sh -c 'curl -s -m 10 -w "\n__CODE__%{http_code}" "$@"; rc=$?; printf "\n__RC__%s\n" "$rc"' sh "$@" 2>/dev/null || true
}
code() { sed -n 's/^__CODE__\([0-9]*\)$/\1/p' <<<"$1"; }
rc()   { sed -n 's/^__RC__\([0-9]*\)$/\1/p' <<<"$1"; }
body() { grep -v -e '^__CODE__' -e '^__RC__' <<<"$1"; }

SVC_A=http://service-a.svc-a-ns:8080
SVC_B=http://service-b.svc-b-ns:8080

# --- scenario 1: browser path through the ingress gateway (port-forward; NodePort 8080 is for humans) ---
kubectl -n istio-ingress port-forward svc/demo-gateway-istio 18080:80 >/dev/null 2>&1 &
PF_PID=$!
for _ in $(seq 1 30); do curl -s -o /dev/null http://localhost:18080/login 2>/dev/null && break; sleep 1; done

happy_path() { # <user> <tenant> <label>
  local jar="$TMP/jar-$1" out http sub tenant ok=1
  curl -s -o /dev/null -c "$jar" -d "username=$1&password=password" http://localhost:18080/login
  out=$(curl -s -b "$jar" -w '\n__CODE__%{http_code}' http://localhost:18080/api/hello)
  http=$(code "$out")
  sub=$(body "$out" | jq -r '.downstream.downstream.sub // empty' 2>/dev/null || true)
  tenant=$(body "$out" | jq -r '.downstream.downstream.tenant_id // empty' 2>/dev/null || true)
  [ "$http" = 200 ] && [ "$sub" = "$1" ] && [ "$tenant" = "$2" ] && ok=0
  report "$3" $ok "HTTP $http sub=$sub tenant_id=$tenant"
}
happy_path alice tenant-001 "1a alice via gateway->portal->a->b"
happy_path bob   tenant-002 "1b bob via gateway->portal->a->b"

# --- scenario 2a: in-mesh client with the wrong Service Identity -> waypoint L7 RBAC ---
OUT=$(incurl rogue-ns curl "$SVC_A/hello")
ok=1; [ "$(code "$OUT")" = 403 ] && grep -q 'RBAC: access denied' <<<"$OUT" && ok=0
report "2a rogue-ns (in mesh, wrong SA) -> a" $ok "HTTP $(code "$OUT") body=$(body "$OUT" | head -c 60)"

# --- scenario 2b: client outside the mesh, plaintext -> ztunnel L4 close under STRICT, no HTTP response ---
OUT=$(incurl default curl "$SVC_A/hello")
RC=$(rc "$OUT"); ok=1
{ [ "$RC" = 56 ] || [ "$RC" = 52 ]; } && ok=0
report "2b default (not in mesh, plaintext) -> a" $ok "curl exit=$RC (52 or 56 accepted) HTTP $(code "$OUT")"

# --- scenarios 3-7: right Service Identity (svc-a-sa) against service-b's waypoint ---
OUT=$(incurl svc-a-ns curl-as-svc-a "$SVC_B/hello")
ok=1; [ "$(code "$OUT")" = 403 ] && grep -q 'RBAC: access denied' <<<"$OUT" && ok=0
report "3  svc-a-sa, no token -> b" $ok "HTTP $(code "$OUT") (403 not 401: no token = anonymous, fails requestPrincipals)"

OUT=$(incurl svc-a-ns curl-as-svc-a -X POST -H "Authorization: Bearer $VALID" "$SVC_B/hello")
ok=1; [ "$(code "$OUT")" = 403 ] && grep -q 'RBAC: access denied' <<<"$OUT" && ok=0
report "4a svc-a-sa, valid token, POST /hello -> b" $ok "HTTP $(code "$OUT")"

OUT=$(incurl svc-a-ns curl-as-svc-a -H "Authorization: Bearer $VALID" "$SVC_B/other")
ok=1; [ "$(code "$OUT")" = 403 ] && grep -q 'RBAC: access denied' <<<"$OUT" && ok=0
report "4b svc-a-sa, valid token, GET /other -> b" $ok "HTTP $(code "$OUT")"

OUT=$(incurl svc-a-ns curl-as-svc-a -H "Authorization: Bearer $EXPIRED" "$SVC_B/hello")
ok=1; [ "$(code "$OUT")" = 401 ] && grep -q 'Jwt is expired' <<<"$OUT" && ok=0
report "5  svc-a-sa, expired token -> b" $ok "HTTP $(code "$OUT") body=$(body "$OUT" | head -c 40)"

OUT=$(incurl svc-a-ns curl-as-svc-a -H "Authorization: Bearer $FORGED" "$SVC_B/hello")
ok=1; [ "$(code "$OUT")" = 401 ] && grep -q 'Jwt verification fails' <<<"$OUT" && ok=0
report "6  svc-a-sa, forged token (same kid) -> b" $ok "HTTP $(code "$OUT") body=$(body "$OUT" | head -c 40)"

OUT=$(incurl svc-a-ns curl-as-svc-a -H "Authorization: Bearer $VALID" "$SVC_B/hello")
SUB=$(body "$OUT" | jq -r '.sub // empty' 2>/dev/null || true)
ok=1; [ "$(code "$OUT")" = 200 ] && [ "$SUB" = alice ] && ok=0
report "7  svc-a-sa, valid token, GET /hello -> b" $ok "HTTP $(code "$OUT") sub=$SUB"

echo
echo "verify: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
```

- [x] **Step 2: Run**

Run: `chmod +x scripts/verify.sh && scripts/verify.sh`
Expected: 10 PASS lines, `verify: 10 passed, 0 failed`, exit 0.

- [x] **Step 3: Diagnose failures (brief §9: policies first, Java last)**

- 2a/3/4 not 403: check `allow-waypoint-to-a/b` exist with the exact waypoint principal, and that `allow-portal-to-a`/`allow-a-to-b` have `targetRefs`. `kubectl --context kind-istio-demo -n istio-system logs ds/ztunnel | grep -i 'policy rejection'`.
- 1a 5xx: `kubectl --context kind-istio-demo -n portal-ns logs deploy/portal`; check `forwardOriginalToken: true` (app 401 on happy path) and kid match (`Jwks doesn't have key`).
- 7 fails but 3-6 pass: check service-b logs for `public-key-location` parse errors or `aud` mismatch.
- `istioctl --context kind-istio-demo ztunnel-config workload -n svc-a-ns` should show `HBONE` and waypoint for service-a.

- [x] **Step 4: Commit checkpoint 4**

```bash
git add scripts/verify.sh
git commit -m "feat: verify.sh, 10/10 scenarios PASS (checkpoint 4)"
```

---

### Task 11: README

**Files:**
- Create: `README.md`

- [x] **Step 1: Write README.md** covering brief §8 items 1–7 in this order, with the final facts from the cluster (nodePort outcome, observed curl exit code for 2b):

1. Title + one-paragraph purpose (from CONTEXT.md). Quick start block:
   ```bash
   scripts/gen-keys.sh && scripts/setup-cluster.sh && scripts/build-and-load.sh && scripts/deploy.sh && scripts/verify.sh
   ```
   plus browser URL and alice/bob credentials; teardown `kind delete cluster --name istio-demo`.
2. ASCII diagram: adapt brief §2 verbatim including rogue-ns/default clients.
3. Hop-by-hop walk-through table (browser -> gateway -> portal -> svc-a waypoint -> service-a -> svc-b waypoint -> service-b) with columns Hop / Enforcer / What is checked / Denial you would see.
4. Table "Provided by Istio vs. application code": service identity (Istio), transport encryption (Istio), service-level authz (Istio, ztunnel L4 + waypoint principals), method/path authz (Istio waypoint), user authentication (portal form login), user identity propagation (portal mints + service-a forwards the Internal JWT; waypoint verifies), tenant claim (portal TENANTS map), in-app claim access (Spring resource server, defense in depth), Authorization Decision Point (application hook).
5. Scenario table (verify.sh) copied from brief §7 with observed results.
6. Troubleshooting list, all eight items from brief §8.4, each with symptom + fix.
7. JWKS production options and rotation (brief §8.5), including the inline-option rotation steps.
8. Authorization Decision Point: where (`HelloController.authorize` in service-a/service-b) and how OPA would plug in (call to OPA sidecar with `{sub, tenant_id, roles, action}`, deny on false).
9. Local run without Istio: `mvn spring-boot:run -Dspring-boot.run.profiles=local` per module (ports 8080/8081/8082), `curl -H "Authorization: Bearer $(scripts/mint-jwt.sh keys/portal.key 300)" localhost:8082/hello`, and login via browser at http://localhost:8080/api/hello.
10. Repository layout (brief §3) and the "demo only" caveats (committed private key, CSRF off, plaintext passwords).

- [x] **Step 2: Commit**

```bash
git add README.md docs/superpowers
git commit -m "docs: README with architecture, hop-by-hop walk-through, troubleshooting, rotation"
```

---

## Self-review

- **Spec coverage:** §0 hard rules -> global constraints + guard in every script (Tasks 7, 10). §1 versions -> Task 7 pins. §2 topology/identity table -> Task 6 Steps 5–8. §3 layout -> file table. §4 Java -> Tasks 2–4 (webmvc rename noted; `RsaKeyConverters` used instead of `@Value RSAPrivateKey` for deterministic PEM parsing, same inputs). §5 manifests -> Task 6 + Task 5 generated files. §6 scripts -> Tasks 5, 7, 10. §7 scenarios -> Task 10 (10 scenarios: 1a 1b 2a 2b 3 4a 4b 5 6 7). §8 README -> Task 11. §9 checkpoints -> Tasks 4, 8, 9, 10 commits. §10 open items -> NodePort attempt with fallback (Task 6 Step 8, Task 9 Step 4); portal `/healthz` permitAll (Task 2); 2b accepts 52/56 and prints observed (Task 10).
- **Placeholder scan:** none; Task 4 references Task 3 content by explicit "identical to" with the differing fields enumerated, which is acceptable because the files are byte-identical apart from the package name.
- **Type consistency:** `TokenMinter.KEY_ID` used in SecurityConfig and the test; `serviceAClient` bean name matches the constructor parameter name in portal `HelloController`; property keys `portal.jwt.private-key`, `portal.jwt.public-key`, `portal.downstream.service-a-url`, `service-a.downstream.service-b-url` match between YAML and Java; SA/Service/pod names match between manifests and verify.sh.
