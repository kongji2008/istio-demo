# 05: Spring Boot line: 3.5.x or 4.x

Type: grilling
Status: resolved
Blocked by:

## Question

The brief says "Spring Boot 3.3+", written before Spring Boot 4 (Nov 2025) existed. The user's version preference elsewhere is "latest stable" (K8s 1.35, Istio 1.31), and their organisation has Spring Boot 4 upgrade tooling. Which line does the demo target?

- **3.5.x** (latest 3.x, OSS support into 2026): matches the brief literally; every resource-server / JwtEncoder example on the web applies unchanged; lowest risk for a demo whose point is Istio, not Spring.
- **4.x** (Spring Framework 7, Jackson 3, Spring Security 7): matches the org's direction; some starter names and `HttpSecurity` DSL details differ, and copy-paste examples are scarcer.

Recommendation: **3.5.x**, because Spring is not what this demo is proving and reviewer familiarity matters more than currency. Record the chosen exact version and the matching Spring Security / Nimbus versions.

## Answer

**Spring Boot 4.x** (user decision, 2026-09-17): Spring Boot 4 is the organisation's current baseline, so the demo must match it even though the brief predates Boot 4. Consequences: Spring Framework 7, Spring Security 7, Jackson 3; research 04 must cite Boot 4 / Security 7 docs for `NimbusJwtEncoder` and the resource-server public-key property, and flag any starter or `HttpSecurity` DSL differences from 3.x. Pin the exact latest 4.x patch at brief assembly (ticket 07).
