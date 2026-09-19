package com.rivulet.gateway.config;

import io.micrometer.common.KeyValue;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.observation.ObservationFilter;
import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.trace.Tracer;
import org.springframework.boot.micrometer.metrics.autoconfigure.MeterRegistryCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.server.observation.ServerRequestObservationContext;

/**
 * Observability configuration for the API gateway.
 *
 * <p>Spring Boot 4 provides Micrometer Observation as the primary abstraction for metrics and
 * traces, with OpenTelemetry available underneath when configured. The application-specific
 * OpenTelemetry {@link Tracer} bean is retained for code that explicitly requires the OTel API.
 *
 * <p>Metric common tags are applied through {@link MeterRegistryCustomizer}. These are metric
 * dimensions; they do not rename or namespace metric names.
 *
 * <p>The request ID is attached to HTTP server observations as a high-cardinality value.
 * High-cardinality observation values are intended for traces rather than metric dimensions.
 */
@Configuration(proxyBeanMethods = false)
public class OpenTelemetryConfig {

    private static final String REQUEST_ID_HEADER = "X-Request-ID";
    private static final String REQUEST_ID_OBSERVATION_KEY = "rivulet.request.id";
    private static final int MAX_REQUEST_ID_LENGTH = 256;

    /**
     * Provides the application tracer for code that requires explicit OpenTelemetry span creation.
     *
     * @param openTelemetry OpenTelemetry managed by Spring Boot
     * @return application tracer
     */
    @Bean
    public Tracer gatewayTracer(OpenTelemetry openTelemetry) {
        return openTelemetry.getTracer("rivulet.gateway");
    }

    /**
     * Adds stable service dimensions to all Micrometer meter registries.
     *
     * @return meter registry customizer
     */
    @Bean
    public MeterRegistryCustomizer<MeterRegistry> metricsCommonTags() {
        return registry ->
                registry.config()
                        .commonTags(
                                "service.namespace", "rivulet",
                                "service.name", "api-gateway");
    }

    /**
     * Adds the client request ID to HTTP server observations as a high-cardinality trace attribute.
     *
     * <p>This deliberately does not use {@code http.request.header.x-request-id} because the
     * OpenTelemetry HTTP semantic convention defines captured request-header values as arrays. The
     * project-specific attribute avoids encoding a scalar request ID with the wrong semantic type.
     *
     * @return observation filter for request correlation
     */
    @Bean
    public ObservationFilter requestIdObservationFilter() {
        return context -> {
            if (!(context instanceof ServerRequestObservationContext serverContext)) {
                return context;
            }

            String requestId =
                    normalizeRequestId(serverContext.getCarrier().getHeader(REQUEST_ID_HEADER));

            if (requestId != null) {
                context.addHighCardinalityKeyValue(
                        KeyValue.of(REQUEST_ID_OBSERVATION_KEY, requestId));
            }

            return context;
        };
    }

    private static String normalizeRequestId(String rawRequestId) {
        if (rawRequestId == null) {
            return null;
        }

        String requestId = rawRequestId.trim();

        if (requestId.isEmpty() || requestId.length() > MAX_REQUEST_ID_LENGTH) {
            return null;
        }

        for (int i = 0; i < requestId.length(); i++) {
            if (Character.isISOControl(requestId.charAt(i))) {
                return null;
            }
        }

        return requestId;
    }
}
