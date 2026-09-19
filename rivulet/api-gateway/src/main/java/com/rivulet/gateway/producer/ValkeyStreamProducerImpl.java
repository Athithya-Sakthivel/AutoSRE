package com.rivulet.gateway.producer;

import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.propagation.W3CTraceContextPropagator;
import io.opentelemetry.context.Context;
import java.util.HashMap;
import java.util.Map;
import java.util.Objects;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.connection.stream.RecordId;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

/**
 * Synchronous Valkey Stream producer with W3C Trace Context injection.
 *
 * <p>The resulting Redis Stream entry contains exactly the fields expected by the downstream Go
 * ingestion worker:
 *
 * <ul>
 *   <li>{@code traceparent} — W3C Trace Context header
 *   <li>{@code tracestate} — W3C Trace State (vendor-specific, often empty)
 *   <li>{@code payload} — serialized domain event JSON
 * </ul>
 *
 * <p><b>Sync with Go Worker:</b> The Go worker's {@code MessageCarrier} in {@code
 * internal/queue/carrier.go} extracts these exact field names via {@code XREADGROUP}. Field names
 * MUST match exactly.
 */
@Component
public final class ValkeyStreamProducerImpl implements ValkeyStreamProducer {

    private static final Logger log = LoggerFactory.getLogger(ValkeyStreamProducerImpl.class);

    private static final String TRACEPARENT = "traceparent";
    private static final String TRACESTATE = "tracestate";

    private final StringRedisTemplate redisTemplate;

    public ValkeyStreamProducerImpl(StringRedisTemplate redisTemplate) {
        this.redisTemplate =
                Objects.requireNonNull(redisTemplate, "redisTemplate must not be null");
    }

    @Override
    public MessageEnvelope produce(String streamName, String payloadJson) {
        Objects.requireNonNull(streamName, "streamName must not be null");
        Objects.requireNonNull(payloadJson, "payloadJson must not be null");

        if (streamName.isBlank()) {
            throw new IllegalArgumentException("streamName must not be blank");
        }

        if (payloadJson.isBlank()) {
            throw new IllegalArgumentException("payloadJson must not be blank");
        }

        // Extract W3C Trace Context from the current OpenTelemetry context.
        // Spring Boot's OTel auto-instrumentation guarantees an active server span
        // for every incoming HTTP request before this code executes.
        Context currentContext = Context.current();

        Map<String, String> carrier = new HashMap<>(2);
        W3CTraceContextPropagator.getInstance().inject(currentContext, carrier, Map::put);

        String traceparent = carrier.getOrDefault(TRACEPARENT, "");
        String tracestate = carrier.getOrDefault(TRACESTATE, "");

        if (traceparent.isBlank()) {
            log.warn(
                    "No valid active OpenTelemetry span found; "
                            + "publishing stream message without traceparent");
        }

        MessageEnvelope envelope = new MessageEnvelope(traceparent, tracestate, payloadJson);

        Span currentSpan = Span.current();

        // Record messaging semantic convention attributes on the active span.
        if (currentSpan.getSpanContext().isValid()) {
            currentSpan.setAttribute("messaging.system", "redis");
            currentSpan.setAttribute("messaging.destination.name", streamName);
            currentSpan.setAttribute("messaging.operation.name", "publish");
            currentSpan.setAttribute("messaging.operation.type", "send");
        }

        RecordId recordId;

        try {
            Map<String, String> fields = envelope.toStreamFields();

            // Synchronous XADD — returns the server-generated stream entry ID.
            recordId = redisTemplate.opsForStream().add(streamName, fields);
        } catch (RuntimeException exception) {
            if (currentSpan.getSpanContext().isValid()) {
                currentSpan.recordException(exception);
                currentSpan.setStatus(StatusCode.ERROR);
            }
            throw exception;
        }

        if (recordId == null) {
            IllegalStateException exception =
                    new IllegalStateException("Valkey XADD returned null record ID");

            if (currentSpan.getSpanContext().isValid()) {
                currentSpan.recordException(exception);
                currentSpan.setStatus(StatusCode.ERROR);
            }
            throw exception;
        }

        String recordIdValue = recordId.getValue();

        if (currentSpan.getSpanContext().isValid()) {
            currentSpan.setAttribute("messaging.message.id", recordIdValue);
        }

        log.debug("Published message to stream {} with record ID {}", streamName, recordIdValue);

        return envelope;
    }
}
