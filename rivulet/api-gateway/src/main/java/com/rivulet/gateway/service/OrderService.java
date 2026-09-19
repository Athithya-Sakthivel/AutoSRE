package com.rivulet.gateway.service;

import com.rivulet.gateway.producer.ValkeyStreamProducer;
import com.rivulet.gateway.telemetry.MetricsRegistry;
import io.micrometer.core.instrument.Timer;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Scope;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.ObjectMapper;

@Service
public class OrderService {

    private static final Logger log = LoggerFactory.getLogger(OrderService.class);
    private static final com.fasterxml.uuid.impl.TimeBasedEpochGenerator EVENT_ID_GENERATOR =
            com.fasterxml.uuid.Generators.timeBasedEpochGenerator();

    private final ValkeyStreamProducer streamProducer;
    private final InventoryService inventoryService;
    private final IdempotencyService idempotencyService;
    private final MetricsRegistry metrics;
    private final Tracer tracer;
    private final ObjectMapper objectMapper;
    private final String streamName;

    public OrderService(
            ValkeyStreamProducer streamProducer,
            InventoryService inventoryService,
            IdempotencyService idempotencyService,
            MetricsRegistry metrics,
            Tracer tracer,
            ObjectMapper objectMapper,
            @Value("${rivulet.stream.name:rivulet.orders.in}") String streamName) {
        this.streamProducer =
                Objects.requireNonNull(streamProducer, "streamProducer must not be null");
        this.inventoryService =
                Objects.requireNonNull(inventoryService, "inventoryService must not be null");
        this.idempotencyService =
                Objects.requireNonNull(idempotencyService, "idempotencyService must not be null");
        this.metrics = Objects.requireNonNull(metrics, "metrics must not be null");
        this.tracer = Objects.requireNonNull(tracer, "tracer must not be null");
        this.objectMapper = Objects.requireNonNull(objectMapper, "objectMapper must not be null");
        this.streamName = Objects.requireNonNull(streamName, "streamName must not be null").trim();
        if (this.streamName.isEmpty()) {
            throw new IllegalArgumentException("rivulet.stream.name must not be blank");
        }
    }

    public String processCheckout(String userId, String sku, int quantity, String requestId) {
        UUID parsedUserId = parseUserId(userId);
        if (sku == null || sku.isBlank())
            throw new IllegalArgumentException("sku must not be blank");
        if (quantity <= 0) throw new IllegalArgumentException("quantity must be greater than zero");

        Timer.Sample sample = Timer.start();
        Span span =
                tracer.spanBuilder("process_checkout")
                        .setAttribute("user.id", parsedUserId.toString())
                        .setAttribute("order.sku", sku)
                        .setAttribute("order.quantity", quantity)
                        .startSpan();

        boolean releaseClaimOnFailure = false;
        try (Scope ignored = span.makeCurrent()) {
            if (!idempotencyService.checkAndSet(requestId)) {
                throw new IllegalStateException("Duplicate request");
            }
            releaseClaimOnFailure = requestId != null && !requestId.isBlank();

            if (!inventoryService.hasSufficientInventory(sku, quantity)) {
                throw new IllegalStateException("Insufficient inventory for SKU: " + sku);
            }

            UUID eventId = EVENT_ID_GENERATOR.generate();
            span.setAttribute("event.id", eventId.toString());

            Map<String, Object> event =
                    Map.of(
                            "event_id",
                            eventId.toString(),
                            "user_id",
                            parsedUserId.toString(),
                            "sku",
                            sku,
                            "quantity",
                            quantity);

            String payloadJson;
            try {
                payloadJson = objectMapper.writeValueAsString(event);
            } catch (JacksonException e) {
                throw new IllegalStateException("Failed to serialize order event", e);
            }

            releaseClaimOnFailure = false; // Do not release if publish is ambiguous
            try {
                streamProducer.produce(streamName, payloadJson);
            } catch (RuntimeException e) {
                metrics.recordStreamWriteFailure();
                throw e;
            }

            log.info("Order event written to stream: eventId={}, stream={}", eventId, streamName);
            metrics.recordOrderProduced();
            return eventId.toString();

        } catch (Exception e) {
            span.recordException(e);
            if (releaseClaimOnFailure) {
                try {
                    idempotencyService.release(requestId);
                } catch (RuntimeException releaseException) {
                    e.addSuppressed(releaseException);
                }
            }
            throw e;
        } finally {
            sample.stop(metrics.getOrderProcessingDuration());
            span.end();
        }
    }

    private static UUID parseUserId(String userId) {
        if (userId == null || userId.isBlank())
            throw new IllegalArgumentException("userId must not be blank");
        try {
            UUID parsed = UUID.fromString(userId);
            if (!parsed.toString().equalsIgnoreCase(userId)) {
                throw new IllegalArgumentException("userId must use canonical UUID format");
            }
            return parsed;
        } catch (IllegalArgumentException e) {
            throw new IllegalArgumentException("userId must be a valid UUID", e);
        }
    }
}
