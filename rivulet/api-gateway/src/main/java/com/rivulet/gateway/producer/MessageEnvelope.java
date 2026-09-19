package com.rivulet.gateway.producer;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Immutable wire envelope for the Valkey Stream consumed by the Go ingestion worker.
 *
 * <p>The stream entry contains the W3C trace context and the serialized domain payload as
 * string-valued fields:
 *
 * <ul>
 *   <li>{@code traceparent} — W3C Trace Context traceparent header
 *   <li>{@code tracestate} — optional W3C Trace State header
 *   <li>{@code payload} — serialized domain event JSON
 * </ul>
 */
public record MessageEnvelope(String traceparent, String tracestate, String payload) {

    public MessageEnvelope {
        traceparent = requireNonBlank(traceparent, "traceparent");
        tracestate = tracestate == null ? "" : tracestate;
        payload = requireNonBlank(payload, "payload");
    }

    /**
     * Converts the envelope to the flat field/value representation used by Valkey XADD.
     *
     * @return insertion-ordered map of stream field names to values
     */
    public Map<String, String> toStreamFields() {
        Map<String, String> fields = new LinkedHashMap<>(3);
        fields.put("traceparent", traceparent);
        fields.put("tracestate", tracestate);
        fields.put("payload", payload);
        return fields;
    }

    /**
     * Re-checks the application-level contract explicitly.
     *
     * @throws IllegalStateException if a required field is missing or blank
     */
    public void validate() {
        if (traceparent.isBlank()) {
            throw new IllegalStateException(
                    "traceparent is required for distributed trace correlation");
        }
        if (payload.isBlank()) {
            throw new IllegalStateException(
                    "payload is required for the Go worker to deserialize the event");
        }
    }

    private static String requireNonBlank(String value, String fieldName) {
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException(fieldName + " must not be null or blank");
        }
        return value;
    }
}
