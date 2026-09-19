package com.rivulet.gateway.controller;

import com.rivulet.gateway.service.OrderService;
import java.util.Map;
import java.util.Objects;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * REST controller for order ingestion.
 *
 * <p>Accepts synchronous checkout requests and delegates validation, idempotency, and event
 * publication to {@link OrderService}.
 *
 * <p>The event contract remains aligned with the Go worker's expected fields: {@code event_id},
 * {@code user_id}, {@code sku}, and {@code quantity}.
 */
@RestController
@RequestMapping("/orders")
public final class OrderController {

    private static final Logger log = LoggerFactory.getLogger(OrderController.class);

    private final OrderService orderService;

    public OrderController(OrderService orderService) {
        this.orderService = Objects.requireNonNull(orderService, "orderService must not be null");
    }

    public record CheckoutRequest(String sku, int quantity) {}

    public record CheckoutResponse(String eventId) {}

    /**
     * Accepts a checkout request and returns the generated event ID.
     *
     * @param userId client/user identifier
     * @param request checkout payload
     * @param requestId optional client request ID used for correlation/idempotency
     * @return accepted event ID or an appropriate error response
     */
    @PostMapping("/{userId}/checkout")
    public ResponseEntity<?> checkout(
            @PathVariable String userId,
            @RequestBody(required = false) CheckoutRequest request,
            @RequestHeader(value = "X-Request-ID", required = false) String requestId) {

        if (userId == null || userId.isBlank()) {
            return badRequest("userId is required");
        }

        if (request == null) {
            return badRequest("request body is required");
        }

        if (request.sku() == null || request.sku().isBlank()) {
            return badRequest("sku is required");
        }

        if (request.quantity() <= 0) {
            return badRequest("quantity must be > 0");
        }

        try {
            String eventId =
                    orderService.processCheckout(
                            userId, request.sku(), request.quantity(), requestId);

            return ResponseEntity.status(HttpStatus.ACCEPTED).body(new CheckoutResponse(eventId));
        } catch (IllegalStateException exception) {
            log.warn("Checkout rejected: {}", safeMessage(exception, "checkout rejected"));

            return ResponseEntity.status(HttpStatus.CONFLICT)
                    .body(errorBody(exception, "checkout rejected"));
        } catch (IllegalArgumentException exception) {
            log.warn(
                    "Checkout validation failed: {}",
                    safeMessage(exception, "invalid checkout request"));

            return ResponseEntity.badRequest()
                    .body(errorBody(exception, "invalid checkout request"));
        } catch (Exception exception) {
            log.error("Unexpected error during checkout", exception);

            return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR)
                    .body(Map.of("error", "internal server error"));
        }
    }

    private static ResponseEntity<Map<String, String>> badRequest(String message) {

        return ResponseEntity.badRequest().body(Map.of("error", message));
    }

    private static Map<String, String> errorBody(Exception exception, String fallbackMessage) {

        return Map.of("error", safeMessage(exception, fallbackMessage));
    }

    private static String safeMessage(Exception exception, String fallbackMessage) {

        String message = exception.getMessage();

        return message == null || message.isBlank() ? fallbackMessage : message;
    }
}
