package com.rivulet.gateway.controller;

import com.rivulet.gateway.chaos.ChaosService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Kubernetes probe endpoints for the API Gateway.
 *
 * <p>Two distinct endpoints are exposed because Kubernetes uses them for different purposes:
 *
 * <ul>
 *   <li>{@code /healthz} backs the startup and liveness probes. It reports process liveness only
 *       and must never fail while the JVM is able to serve requests. A failure here restarts the
 *       container.
 *   <li>{@code /readyz} backs the readiness probe. It reports whether the pod should receive
 *       traffic. A failure here removes the pod from the Service endpoints while the container
 *       keeps running.
 * </ul>
 *
 * <p>The chaos unhealthy fault is deliberately wired to {@code /readyz} only. This models a
 * dependency-health degradation: the process is alive but cannot serve traffic, so the pod drops
 * out of the load-balancer rotation without being restarted.
 */
@RestController
public class HealthController {

    private static final String OK_BODY = "{\"status\":\"ok\"}";
    private static final String UNHEALTHY_BODY = "{\"status\":\"unhealthy\"}";

    private final ChaosService chaosService;

    public HealthController(ChaosService chaosService) {
        this.chaosService = chaosService;
    }

    /**
     * Liveness and startup probe target. Returns 200 whenever the process can serve HTTP requests.
     *
     * <p>This endpoint intentionally ignores the chaos unhealthy flag. Routing chaos state through
     * a liveness probe would cause Kubernetes to restart the container, which destroys the
     * observable "Running but not Ready" state that the readiness-failure incident is designed to
     * produce.
     */
    @GetMapping("/healthz")
    public ResponseEntity<String> liveness() {
        return ResponseEntity.ok(OK_BODY);
    }

    /**
     * Readiness probe target. Returns 503 while the chaos unhealthy fault is active, otherwise 200.
     */
    @GetMapping("/readyz")
    public ResponseEntity<String> readiness() {
        if (chaosService.isUnhealthy()) {
            return ResponseEntity.status(503).body(UNHEALTHY_BODY);
        }
        return ResponseEntity.ok(OK_BODY);
    }
}
