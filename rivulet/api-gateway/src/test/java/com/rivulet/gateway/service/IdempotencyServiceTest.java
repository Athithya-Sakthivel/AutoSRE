package com.rivulet.gateway.service;

import static org.assertj.core.api.Assertions.assertThat;

import com.redis.testcontainers.RedisContainer;
import com.rivulet.gateway.telemetry.MetricsRegistry;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import java.time.Duration;
import java.util.Set;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.context.annotation.Bean;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

@Testcontainers
@SpringBootTest
@ActiveProfiles("test")
class IdempotencyServiceTest {

    @Container
    @ServiceConnection(name = "redis")
    static RedisContainer valkey = new RedisContainer("valkey/valkey:8-alpine");

    @TestConfiguration
    static class TestConfig {
        @Bean
        MeterRegistry meterRegistry() {
            return new SimpleMeterRegistry();
        }
    }

    @Autowired private StringRedisTemplate redisTemplate;

    @Autowired private MetricsRegistry metrics;

    private IdempotencyService service;

    @BeforeEach
    void setUp() {
        Set<String> keys = redisTemplate.keys("idempotency:*");
        if (keys != null && !keys.isEmpty()) {
            redisTemplate.delete(keys);
        }
        service = new IdempotencyService(redisTemplate, metrics, Duration.ofHours(1));
    }

    @Test
    void checkAndSet_firstRequest_returnsTrue() {
        assertThat(service.checkAndSet("req-001")).isTrue();
    }

    @Test
    void checkAndSet_duplicateRequest_returnsFalse() {
        service.checkAndSet("req-002");
        assertThat(service.checkAndSet("req-002")).isFalse();
    }

    @Test
    void checkAndSet_nullRequestId_returnsTrue() {
        assertThat(service.checkAndSet(null)).isTrue();
    }

    @Test
    void checkAndSet_blankRequestId_returnsTrue() {
        assertThat(service.checkAndSet("")).isTrue();
    }

    @Test
    void release_allowsReclaimAfterRelease() {
        service.checkAndSet("req-005");
        assertThat(service.checkAndSet("req-005")).isFalse();

        service.release("req-005");

        assertThat(service.checkAndSet("req-005")).isTrue();
    }

    @Test
    void checkAndSet_setsTtlOnKey() {
        service.checkAndSet("req-006");
        Long ttl = redisTemplate.getExpire("idempotency:req-006");
        assertThat(ttl).isGreaterThan(0);
    }
}
