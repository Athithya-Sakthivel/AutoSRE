package com.rivulet.gateway.chaos;

import com.sun.net.httpserver.HttpExchange;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import org.springframework.stereotype.Component;

/**
 * HTTP handler for the isolated chaos injection server.
 *
 * <p>This is deliberately not a Spring MVC controller. It is registered directly with {@code
 * com.sun.net.httpserver.HttpServer}.
 */
@Component
public class ChaosController {

    private static final String JSON_CONTENT_TYPE = "application/json; charset=utf-8";

    private static final String METHOD_NOT_ALLOWED = "{\"error\":\"method not allowed\"}";

    private final ChaosService chaosService;

    public ChaosController(ChaosService chaosService) {
        this.chaosService = chaosService;
    }

    public void handleHealthz(HttpExchange exchange) throws IOException {
        if (!requireMethod(exchange, "GET")) {
            return;
        }

        sendResponse(exchange, 200, "{\"status\":\"ok\"}");
    }

    public void handleLeakDb(HttpExchange exchange) throws IOException {
        if (!requireMethod(exchange, "POST")) {
            return;
        }

        sendResponse(exchange, 200, chaosService.leakDb());
    }

    public void handleCpuSpin(HttpExchange exchange) throws IOException {
        if (!requireMethod(exchange, "POST")) {
            return;
        }

        sendResponse(exchange, 200, chaosService.cpuSpin());
    }

    public void handleLatency(HttpExchange exchange) throws IOException {
        if (!requireMethod(exchange, "POST")) {
            return;
        }

        sendResponse(exchange, 200, chaosService.latency());
    }

    public void handleReset(HttpExchange exchange) throws IOException {
        if (!requireMethod(exchange, "POST")) {
            return;
        }

        sendResponse(exchange, 200, chaosService.reset());
    }

    private boolean requireMethod(HttpExchange exchange, String expectedMethod) throws IOException {
        if (expectedMethod.equalsIgnoreCase(exchange.getRequestMethod())) {
            return true;
        }

        exchange.getResponseHeaders().set("Allow", expectedMethod);
        sendResponse(exchange, 405, METHOD_NOT_ALLOWED);
        return false;
    }

    private void sendResponse(HttpExchange exchange, int status, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);

        exchange.getResponseHeaders().set("Content-Type", JSON_CONTENT_TYPE);

        exchange.sendResponseHeaders(status, bytes.length);

        try (OutputStream outputStream = exchange.getResponseBody()) {
            outputStream.write(bytes);
        }
    }
}
