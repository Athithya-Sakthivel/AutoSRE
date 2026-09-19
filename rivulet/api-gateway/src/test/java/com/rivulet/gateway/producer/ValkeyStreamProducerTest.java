package com.rivulet.gateway.producer;

import static org.assertj.core.api.Assertions.assertThat;

import com.redis.testcontainers.RedisContainer;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Scope;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.data.redis.connection.stream.MapRecord;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

@Testcontainers
@SpringBootTest
@ActiveProfiles("test")
class ValkeyStreamProducerTest {

    @Container
    @ServiceConnection(name = "redis")
    static RedisContainer valkey = new RedisContainer("valkey/valkey:8-alpine");

    @Autowired private ValkeyStreamProducer producer;

    @Autowired private StringRedisTemplate redisTemplate;

    @Autowired private Tracer tracer;

    private static final String TEST_STREAM = "test.rivulet.orders.in";

    @Test
    void produce_publishesMessageWithCorrectFields() {
        String payload = "{\"event_id\":\"e1\",\"user_id\":\"u1\",\"sku\":\"s1\",\"quantity\":1}";

        MessageEnvelope envelope = producer.produce(TEST_STREAM, payload);

        assertThat(envelope).isNotNull();
        assertThat(envelope.payload()).isEqualTo(payload);
        assertThat(envelope.traceparent()).isNotBlank();

        List<MapRecord<String, Object, Object>> records =
                redisTemplate
                        .opsForStream()
                        .range(TEST_STREAM, org.springframework.data.domain.Range.unbounded());

        assertThat(records).hasSize(1);

        Map<Object, Object> fields = records.get(0).getValue();
        assertThat(fields).containsKeys("traceparent", "tracestate", "payload");
        assertThat(fields.get("payload")).isEqualTo(payload);
    }

    @Test
    void produce_injectsW3CTraceContextFromActiveSpan() {
        Span span = tracer.spanBuilder("test-producer-span").startSpan();
        try (Scope ignored = span.makeCurrent()) {
            String payload = "{\"event_id\":\"e2\"}";
            MessageEnvelope envelope = producer.produce(TEST_STREAM, payload);

            String expectedTraceId = span.getSpanContext().getTraceId();
            assertThat(envelope.traceparent()).contains(expectedTraceId);
        } finally {
            span.end();
        }
    }

    @Test
    void produce_rejectsNullStreamName() {
        org.junit.jupiter.api.Assertions.assertThrows(
                NullPointerException.class, () -> producer.produce(null, "{\"event_id\":\"e4\"}"));
    }

    @Test
    void produce_rejectsNullPayload() {
        org.junit.jupiter.api.Assertions.assertThrows(
                NullPointerException.class, () -> producer.produce(TEST_STREAM, null));
    }
}
