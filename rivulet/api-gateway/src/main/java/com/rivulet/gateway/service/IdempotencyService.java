package com.rivulet.gateway.service;

import com.rivulet.gateway.telemetry.MetricsRegistry;
import java.time.Duration;
import java.util.Objects;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Service;

/**
 * API-level idempotency reservation service.
 *
 * <p>This prevents duplicate stream submissions caused by clients retrying the same request while
 * the request is still within the configured retry window.
 *
 * <p>The durable business-level deduplication guarantee remains the database {@code
 * orders.event_id} uniqueness constraint enforced by the Go worker.
 */
@Service
public class IdempotencyService {

    private static final Logger log = LoggerFactory.getLogger(IdempotencyService.class);
    private static final String KEY_PREFIX = "idempotency:";

    private final StringRedisTemplate redisTemplate;
    private final MetricsRegistry metrics;
    private final Duration ttl;

    public IdempotencyService(
            StringRedisTemplate redisTemplate,
            MetricsRegistry metrics,
            @Value("${rivulet.idempotency.ttl:24h}") Duration ttl) {
        this.redisTemplate =
                Objects.requireNonNull(redisTemplate, "redisTemplate must not be null");
        this.metrics = Objects.requireNonNull(metrics, "metrics must not be null");
        this.ttl = Objects.requireNonNull(ttl, "ttl must not be null");

        if (ttl.isZero() || ttl.isNegative()) {
            throw new IllegalArgumentException("rivulet.idempotency.ttl must be greater than zero");
        }
    }

    /**
     * Attempts to reserve an idempotency key.
     *
     * @param requestId client-provided idempotency key, typically X-Request-ID
     * @return {@code true} when this request successfully owns the key; {@code false} when another
     *     request already owns it
     * @throws IllegalStateException when Redis does not return an unambiguous claim result
     */
    public boolean checkAndSet(String requestId) {
        if (requestId == null || requestId.isBlank()) {
            log.debug(
                    "Request has no idempotency key; allowing request without API-level deduplication");
            return true;
        }

        String key = KEY_PREFIX + requestId;
        Boolean claimed = redisTemplate.opsForValue().setIfAbsent(key, "1", ttl);

        if (Boolean.TRUE.equals(claimed)) {
            return true;
        }

        if (Boolean.FALSE.equals(claimed)) {
            log.info("Duplicate request detected");
            metrics.recordIdempotentHit();
            return false;
        }

        /*
         * Spring documents null as a possible result for pipelined/transactional
         * execution. Treating that as "new request" would defeat the purpose of
         * the idempotency guard, so fail closed instead.
         */
        throw new IllegalStateException("Idempotency store returned no unambiguous claim result");
    }

    /**
     * Releases a reservation that was acquired but never published.
     *
     * @param requestId idempotency key
     */
    public void release(String requestId) {
        if (requestId == null || requestId.isBlank()) {
            return;
        }

        redisTemplate.delete(KEY_PREFIX + requestId);
    }
}
