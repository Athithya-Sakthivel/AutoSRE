package com.rivulet.gateway;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Rivulet API Gateway application entry point.
 *
 * <p>This service is the synchronous producer side of the Rivulet platform. It accepts HTTP
 * checkout requests, performs pre-flight validation and idempotency checks, and publishes order
 * events to a Valkey Stream for asynchronous processing by the Go ingestion worker.
 *
 * <p><b>Ownership:</b> This service exclusively owns all PostgreSQL schema migrations via Flyway.
 */
@SpringBootApplication
public final class ApiGatewayApplication {

    private ApiGatewayApplication() {
        // Prevent accidental instantiation.
    }

    public static void main(String[] args) {
        SpringApplication.run(ApiGatewayApplication.class, args);
    }
}
