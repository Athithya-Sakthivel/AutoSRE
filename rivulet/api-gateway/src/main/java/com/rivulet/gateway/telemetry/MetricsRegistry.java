package com.rivulet.gateway.telemetry;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.springframework.stereotype.Component;

@Component
public class MetricsRegistry {

    private final Counter ordersProduced;
    private final Counter idempotentHits;
    private final Counter streamWriteFailures;
    private final Timer orderProcessingDuration;

    public MetricsRegistry(MeterRegistry registry) {
        this.ordersProduced =
                Counter.builder("rivulet.orders.produced")
                        .description("Total orders successfully written to Valkey stream")
                        .register(registry);

        this.idempotentHits =
                Counter.builder("rivulet.orders.idempotent_hits")
                        .description("Duplicate requests rejected by idempotency check")
                        .register(registry);

        this.streamWriteFailures =
                Counter.builder("rivulet.orders.stream_write_failures")
                        .description("Failed XADD operations to Valkey stream")
                        .register(registry);

        this.orderProcessingDuration =
                Timer.builder("rivulet.order_processing_duration")
                        .description("Time from request receipt to stream write completion")
                        .register(registry);
    }

    public void recordOrderProduced() {
        ordersProduced.increment();
    }

    public void recordIdempotentHit() {
        idempotentHits.increment();
    }

    public void recordStreamWriteFailure() {
        streamWriteFailures.increment();
    }

    public Timer getOrderProcessingDuration() {
        return orderProcessingDuration;
    }
}
