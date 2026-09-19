package com.rivulet.gateway.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;

import com.rivulet.gateway.producer.MessageEnvelope;
import com.rivulet.gateway.producer.ValkeyStreamProducer;
import com.rivulet.gateway.telemetry.MetricsRegistry;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.trace.Tracer;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import tools.jackson.databind.ObjectMapper;
import tools.jackson.databind.json.JsonMapper;

@ExtendWith(MockitoExtension.class)
class OrderServiceTest {

    @Mock private ValkeyStreamProducer streamProducer;
    @Mock private InventoryService inventoryService;
    @Mock private IdempotencyService idempotencyService;

    private MetricsRegistry metrics;
    private Tracer tracer;
    private ObjectMapper objectMapper;
    private OrderService orderService;

    private static final String STREAM_NAME = "test.rivulet.orders.in";
    private static final String VALID_USER_ID = "00000000-0000-0000-0000-000000000001";

    @BeforeEach
    void setUp() {
        MeterRegistry registry = new SimpleMeterRegistry();
        metrics = new MetricsRegistry(registry);
        tracer = OpenTelemetry.noop().getTracer("test");
        objectMapper = JsonMapper.builder().build();

        orderService =
                new OrderService(
                        streamProducer,
                        inventoryService,
                        idempotencyService,
                        metrics,
                        tracer,
                        objectMapper,
                        STREAM_NAME);
    }

    @Test
    void processCheckout_success_publishesToStream() {
        when(idempotencyService.checkAndSet(anyString())).thenReturn(true);
        when(inventoryService.hasSufficientInventory(anyString(), eq(1))).thenReturn(true);
        when(streamProducer.produce(eq(STREAM_NAME), anyString()))
                .thenReturn(new MessageEnvelope("00-trace-01", "", "{}"));

        String eventId = orderService.processCheckout(VALID_USER_ID, "SKU-1", 1, "req-100");

        assertThat(eventId).isNotBlank();
        verify(streamProducer).produce(eq(STREAM_NAME), anyString());
    }

    @Test
    void processCheckout_duplicateRequest_throwsIllegalState() {
        when(idempotencyService.checkAndSet("req-dup")).thenReturn(false);

        assertThatThrownBy(() -> orderService.processCheckout(VALID_USER_ID, "SKU-1", 1, "req-dup"))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("Duplicate");

        verify(streamProducer, never()).produce(anyString(), anyString());
    }

    @Test
    void processCheckout_insufficientInventory_throwsIllegalState() {
        when(idempotencyService.checkAndSet("req-ins")).thenReturn(true);
        when(inventoryService.hasSufficientInventory("SKU-1", 999)).thenReturn(false);

        assertThatThrownBy(
                        () -> orderService.processCheckout(VALID_USER_ID, "SKU-1", 999, "req-ins"))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("Insufficient inventory");

        verify(streamProducer, never()).produce(anyString(), anyString());
        verify(idempotencyService).release("req-ins");
    }

    @Test
    void processCheckout_invalidUserId_throwsIllegalArgument() {
        assertThatThrownBy(() -> orderService.processCheckout("not-a-uuid", "SKU-1", 1, "req-inv"))
                .isInstanceOf(IllegalArgumentException.class);

        verify(idempotencyService, never()).checkAndSet(anyString());
    }

    @Test
    void processCheckout_blankSku_throwsIllegalArgument() {
        assertThatThrownBy(() -> orderService.processCheckout(VALID_USER_ID, "", 1, "req-blank"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("sku");
    }

    @Test
    void processCheckout_zeroQuantity_throwsIllegalArgument() {
        assertThatThrownBy(
                        () -> orderService.processCheckout(VALID_USER_ID, "SKU-1", 0, "req-zero"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("quantity");
    }

    @Test
    void processCheckout_streamPublishFails_propagatesException() {
        when(idempotencyService.checkAndSet("req-fail")).thenReturn(true);
        when(inventoryService.hasSufficientInventory("SKU-1", 1)).thenReturn(true);
        when(streamProducer.produce(eq(STREAM_NAME), anyString()))
                .thenThrow(new RuntimeException("Valkey connection refused"));

        assertThatThrownBy(
                        () -> orderService.processCheckout(VALID_USER_ID, "SKU-1", 1, "req-fail"))
                .isInstanceOf(RuntimeException.class)
                .hasMessageContaining("Valkey connection refused");

        verify(idempotencyService, never()).release("req-fail");
    }
}
