package com.rivulet.gateway;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.output.MigrateResult;
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
 *
 * <h2>Two run modes</h2>
 *
 * <p><b>Normal (default):</b>
 *
 * <pre>{@code java -jar /app/app.jar}</pre>
 *
 * Boots the full Spring context — Tomcat on {@code :8080}, chaos plane on {@code :8081}, HikariCP,
 * Lettuce, OpenTelemetry, and Flyway (when {@code spring.flyway.enabled=true}).
 *
 * <p><b>Migration-only:</b>
 *
 * <pre>{@code MIGRATE_ONLY=true java -jar /app/app.jar}</pre>
 *
 * or
 *
 * <pre>{@code java -jar /app/app.jar --migrate-only}</pre>
 *
 * Runs Flyway against the configured PostgreSQL database using plain JDBC and exits. No Spring
 * context is created — no Redis auto-configuration, no Tomcat, no chaos server, no OTel. Only the
 * {@code PG*} environment variables are read.
 *
 * <p>This mode exists because a Kubernetes migration Job should not boot the entire application
 * just to invoke {@code Flyway.migrate()}. Every Spring bean on the classpath is a potential
 * startup failure unrelated to schema migration (e.g. binding {@code spring.data.redis.port} to
 * {@code DataRedisProperties} when the injected {@code VALKEY_PORT} is not an integer). Migrations
 * must be the smallest possible program.
 */
@SpringBootApplication
public final class ApiGatewayApplication {

    /** Environment variable that switches the JVM into migration-only mode. */
    private static final String MIGRATE_ONLY_ENV = "MIGRATE_ONLY";

    /** Command-line flag that switches the JVM into migration-only mode. */
    private static final String MIGRATE_ONLY_ARG = "--migrate-only";

    private ApiGatewayApplication() {
        // Prevent accidental instantiation.
    }

    public static void main(String[] args) {
        if (isMigrateOnly(args)) {
            System.exit(runMigrations());
        }
        SpringApplication.run(ApiGatewayApplication.class, args);
    }

    private static boolean isMigrateOnly(String[] args) {
        if (Boolean.parseBoolean(System.getenv(MIGRATE_ONLY_ENV))) {
            return true;
        }
        for (String arg : args) {
            if (MIGRATE_ONLY_ARG.equals(arg)) {
                return true;
            }
        }
        return false;
    }

    private static int runMigrations() {
        String host = env("PGHOST", "localhost");
        String port = env("PGPORT", "5432");
        String database = env("PGDATABASE", "app");
        String user = env("PGUSER", "app");
        String password = env("PGPASSWORD", "password");

        String url = "jdbc:postgresql://" + host + ":" + port + "/" + database;
        System.out.printf("MIGRATE_ONLY: connecting to %s as user '%s'%n", url, user);

        try {
            Flyway flyway =
                    Flyway.configure()
                            .dataSource(url, user, password)
                            .locations("classpath:db/migration")
                            .baselineOnMigrate(true)
                            .validateOnMigrate(true)
                            .load();

            MigrateResult result = flyway.migrate();
            System.out.printf(
                    "MIGRATE_ONLY: %d migration(s) applied, schema now at version %s%n",
                    result.migrationsExecuted, result.targetSchemaVersion);
            return 0;
        } catch (Exception e) {
            System.err.println("MIGRATE_ONLY: migration failed: " + e.getMessage());
            e.printStackTrace(System.err);
            return 1;
        }
    }

    private static String env(String name, String fallback) {
        String value = System.getenv(name);
        return (value == null || value.isBlank()) ? fallback : value;
    }
}
