package com.rivulet.gateway.controller;

import org.springframework.boot.availability.ApplicationAvailability;
import org.springframework.boot.availability.LivenessState;
import org.springframework.boot.availability.ReadinessState;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Kubernetes-compatible application availability endpoints.
 *
 * <p>The custom {@code /healthz} and {@code /readyz} paths are retained for compatibility with the
 * existing deployment and worker configuration.
 *
 * <p>The endpoints expose Spring Boot's application availability state rather than performing
 * external dependency checks. This keeps liveness independent of databases, caches, or other shared
 * services.
 *
 * <p>Spring Boot Actuator also provides native liveness and readiness health groups. These custom
 * endpoints are compatibility endpoints and do not replace those Actuator endpoints.
 */
@RestController
public final class HealthController {

    private final ApplicationAvailability applicationAvailability;

    public HealthController(ApplicationAvailability applicationAvailability) {
        this.applicationAvailability = applicationAvailability;
    }

    /**
     * Returns HTTP 200 while the application is live and HTTP 503 otherwise.
     *
     * @return liveness response
     */
    @GetMapping("/healthz")
    public ResponseEntity<String> healthz() {
        if (applicationAvailability.getLivenessState() == LivenessState.CORRECT) {
            return ResponseEntity.ok("ok");
        }

        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body("not live");
    }

    /**
     * Returns HTTP 200 while the application accepts traffic and HTTP 503 otherwise.
     *
     * @return readiness response
     */
    @GetMapping("/readyz")
    public ResponseEntity<String> readyz() {
        if (applicationAvailability.getReadinessState() == ReadinessState.ACCEPTING_TRAFFIC) {
            return ResponseEntity.ok("ok");
        }

        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body("not ready");
    }
}
