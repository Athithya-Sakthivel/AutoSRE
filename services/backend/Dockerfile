# Build stage
FROM docker.io/library/maven:3.9.9-eclipse-temurin-21-alpine@sha256:5a8b906c4faa11d33f6c74758f67db8eac25441e14b0729f6d50ff78992be58a AS builder

WORKDIR /build

COPY pom.xml .
RUN mvn dependency:go-offline

COPY src ./src
RUN mvn clean package -DskipTests

# Runtime stage
FROM docker.io/library/eclipse-temurin:21-jre-alpine@sha256:974b08960c5d96694c780e65b2d5705268ab1e1ca1a0dd0caf4ba6c3fe34d699

# Install curl for health checks (optional)
RUN apk add --no-cache curl

# Application Insights Java agent version
ENV APPINSIGHTS_AGENT_VERSION=3.7.9

# Download Application Insights agent
RUN wget -O /opt/applicationinsights-agent.jar \
    "https://github.com/microsoft/ApplicationInsights-Java/releases/download/${APPINSIGHTS_AGENT_VERSION}/applicationinsights-agent-${APPINSIGHTS_AGENT_VERSION}.jar"

WORKDIR /app

COPY --from=builder /build/target/*.jar app.jar

# Create non-root user
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

# Health check using actuator
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s \
  CMD curl -f http://localhost:8080/actuator/health || exit 1

# Run with Application Insights Java agent
ENTRYPOINT ["java", "-javaagent:/opt/applicationinsights-agent.jar", "-jar", "/app/app.jar"]