# syntax=docker/dockerfile:1.7

# ---------------------------------------------------------------------------
# Stage 1: Build
# ---------------------------------------------------------------------------
# Uses Eclipse Temurin JDK 25 with Maven 3.9 for compilation.
# BuildKit cache mounts persist ~/.m2 across builds for fast rebuilds.
# ---------------------------------------------------------------------------
FROM maven:3.9.16-eclipse-temurin-25-alpine AS build

WORKDIR /build

# Copy dependency descriptors first to maximize layer caching.
# Only changes to pom.xml will invalidate the dependency download layer.
COPY pom.xml ./

# Download all dependencies (cached across builds via BuildKit mount).
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -DskipTests dependency:go-offline

# Copy source code after dependencies are cached.
COPY src ./src

# Build the fat JAR. The spring-boot-maven-plugin repackages the artifact
# with all dependencies nested under BOOT-INF/, producing a single
# self-contained executable JAR.
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -DskipTests clean package

# ---------------------------------------------------------------------------
# Stage 2: Runtime
# ---------------------------------------------------------------------------
# Uses Eclipse Temurin JRE 25 on Alpine for minimal footprint (~80MB).
# No JDK, no build tools in production — near-zero attack surface.
#
# OpenTelemetry is handled natively by Spring Boot's OTel starter; no Java
# agent is required. This replaces the previous Azure Application Insights
# agent approach with a standards-based, vendor-neutral observability stack.
# ---------------------------------------------------------------------------
FROM eclipse-temurin:25-jre-alpine

WORKDIR /app

# Install curl for the HEALTHCHECK directive only.
# Alpine's curl is ~3MB and the only additional package in the runtime image.
RUN apk add --no-cache curl

# Copy the fat JAR from the build stage.
COPY --from=build /build/target/api-gateway-*.jar /app/app.jar

# Inject build metadata for telemetry correlation.
# Passed via: docker build --build-arg GIT_SHA=$(git rev-parse --short HEAD)
# This value flows into Spring Boot's OTel resource attributes via the
# GIT_VERSION environment variable, enabling trace-to-commit correlation
# in OpenObserve. Matches the Go worker's GIT_VERSION injection pattern.
ARG GIT_SHA=unknown
ENV GIT_VERSION=${GIT_SHA}

# Create a dedicated non-root user. UID 65532 is the standard nonroot UID
# used by distroless images and matches the Go worker's runtime user for
# cross-service consistency in shared namespaces.
RUN addgroup -S -g 65532 appgroup \
    && adduser -S -D -H -u 65532 -G appgroup appuser \
    && chown -R appuser:appgroup /app

USER appuser

# Port 8080 is the main HTTP server (Spring MVC + Actuator + custom probes).
# Port 8081 (chaos injection) is intentionally NOT exposed — it is isolated
# via Kubernetes NetworkPolicy and never routed through Service/Ingress.
# This prevents the evaluation harness's fault plane from being accidentally
# exposed to external traffic.
EXPOSE 8080

# Docker HEALTHCHECK uses the Spring Boot Actuator health endpoint.
# This is distinct from the custom /healthz and /readyz endpoints used by
# Kubernetes liveness/readiness probes. start-period=60s accounts for
# Flyway migrations, HikariCP pool warm-up, and Lettuce connection init.
HEALTHCHECK --interval=30s \
    --timeout=5s \
    --start-period=60s \
    --retries=3 \
    CMD curl --fail --silent --show-error \
        http://127.0.0.1:8080/actuator/health \
        >/dev/null || exit 1

# Exec form ensures proper signal handling (SIGTERM → Spring Boot graceful
# shutdown sequence). No Java agent is needed — OpenTelemetry is configured
# natively via spring-boot-starter-opentelemetry and management.opentelemetry.*
# properties in application.yml.
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
