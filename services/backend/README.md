# Task API Service

Production-grade Spring Boot REST API with:

- JWT authentication and role-based authorization
- PostgreSQL persistence via Flyway migrations
- Azure Key Vault for secrets
- Azure Application Insights for telemetry (requests, dependencies, traces, exceptions, metrics)
- Docker and Kubernetes-ready

---

## Architecture

```
Client
   │
   ▼
Spring Boot REST API (Java 21)
   │
   ├── Spring Security + JWT
   ├── Spring Data JPA + PostgreSQL
   ├── Azure Key Vault (secrets)
   └── Application Insights Java Agent (auto-instrumentation)
```

All telemetry is automatically collected by the **Application Insights Java agent** (no custom code). It exports to a workspace-based Application Insights resource, which stores data in Log Analytics (`AppRequests`, `AppDependencies`, `AppTraces`, `AppExceptions`, `AppMetrics`).

---

## Prerequisites

- Java 21 (LTS)
- Maven 3.9+
- Docker
- Azure CLI (`az`) logged in
- Bash (Linux/WSL/macOS)

---

## Quick Start

### 1. Create Azure resources

```bash
cd service
bash temp_az_resources.sh
```

This creates:

- Resource group `temp-az-<subscription-last4>`
- Key Vault `az-temp-kv-101` (with secrets)
- Log Analytics workspace `task-api-logs-<last4>`
- Application Insights `task-api-insights` (linked to workspace)

### 2. Run end-to-end test

```bash
bash test_e2e_locally.sh
```

The script:

- Starts PostgreSQL in Docker
- Updates Key Vault DatabaseUrl to Docker bridge IP
- Downloads and attaches Application Insights Java agent
- Starts Spring Boot, runs curl tests (register, login, create task, fetch tasks)
- Stops app gracefully
- Polls Log Analytics for correlated telemetry
- Prints counts and correlation evidence

---

## Build and Unit Tests

```bash
mvn clean test
```

Runs unit tests (Mockito) and integration tests (Testcontainers with PostgreSQL).

---

## Directory Structure (annotated)

```
service/
├── Dockerfile                              # Multi-stage Docker build with Application Insights agent
├── pom.xml                                 # Maven configuration: Spring Boot 3.5.16, Azure SDK, JJWT, Testcontainers
├── temp_az_resources.sh                    # Creates Azure resources (Key Vault, Log Analytics, App Insights) idempotently
├── test_e2e_locally.sh                     # End-to-end local test with telemetry verification (robust polling)
├── observability.md                        # Observability guide and known pitfalls
├── output.txt                              # Captured output from script runs (debugging)
├── src/
│   ├── main/
│   │   ├── java/com/prod/taskapi/
│   │   │   ├── TaskApiApplication.java     # Spring Boot entry point
│   │   │   ├── config/
│   │   │   │   ├── AzureConfig.java        # Provides DefaultAzureCredential bean for Azure SDK
│   │   │   │   └── SecurityConfig.java     # Spring Security: JWT filter, password encoder, stateless sessions
│   │   │   ├── controller/
│   │   │   │   ├── AuthController.java     # REST endpoints: /api/v1/auth/register, /api/v1/auth/login
│   │   │   │   └── TaskController.java     # REST endpoints: /api/v1/tasks CRUD
│   │   │   ├── dto/
│   │   │   │   ├── JwtResponse.java        # DTO for JWT response
│   │   │   │   ├── LoginRequest.java       # DTO for login request
│   │   │   │   ├── RegisterRequest.java    # DTO for registration request
│   │   │   │   ├── TaskRequest.java        # DTO for task create/update
│   │   │   │   └── TaskResponse.java       # DTO for task response
│   │   │   ├── entity/
│   │   │   │   ├── Role.java               # Enum: USER, ADMIN
│   │   │   │   ├── Status.java             # Enum: PENDING, IN_PROGRESS, COMPLETED, CANCELLED
│   │   │   │   ├── Task.java               # JPA entity: tasks table
│   │   │   │   └── User.java               # JPA entity: users table
│   │   │   ├── exception/
│   │   │   │   ├── CustomExceptions.java   # Placeholder for custom exceptions
│   │   │   │   └── GlobalExceptionHandler.java # REST exception handler with structured errors
│   │   │   ├── repository/
│   │   │   │   ├── TaskRepository.java     # Spring Data JPA repository for Task
│   │   │   │   └── UserRepository.java     # Spring Data JPA repository for User
│   │   │   ├── security/
│   │   │   │   ├── JwtAuthenticationFilter.java # Filter to validate JWT from Authorization header
│   │   │   │   ├── JwtService.java         # JWT generation and validation (HMAC SHA-256)
│   │   │   │   └── UserDetailsServiceImpl.java # Loads UserDetails for Spring Security
│   │   │   └── service/
│   │   │       ├── AuthService.java        # Business logic for registration and login
│   │   │       └── TaskService.java        # Business logic for task CRUD
│   │   └── resources/
│   │       ├── application.yml             # Main config: Key Vault property source, DB, JWT, metrics, logging
│   │       ├── db/migration/
│   │       │   ├── V1__create_users.sql    # Flyway migration: users table
│   │       │   └── V2__create_tasks.sql    # Flyway migration: tasks table with FK to users
│   │       └── logback-spring.xml          # Logback configuration (console appender)
│   └── test/
│       ├── java/com/prod/taskapi/
│       │   ├── integration/
│       │   │   ├── AuthIntegrationTest.java # Integration test for auth endpoints (Testcontainers)
│       │   │   ├── BaseIntegrationTest.java # Base class with Testcontainers PostgreSQL
│       │   │   ├── TaskIntegrationTest.java # Integration test for task endpoints
│       │   │   └── TestcontainersConfiguration.java # Spring Boot Testcontainers config with @ServiceConnection
│       │   └── unit/
│       │       ├── AuthServiceTest.java    # Unit tests for AuthService (Mockito)
│       │       └── TaskServiceTest.java    # Unit tests for TaskService (Mockito)
│       └── resources/
│           └── application-test.yml        # Test config: disable Key Vault, use Testcontainers DB
├── target/                                 # Build output (compiled classes, test reports)
└── ...
```

---

## Observability

### Telemetry Tables

| Table             | Description                       |
| ----------------- | --------------------------------- |
| `AppRequests`     | HTTP request telemetry            |
| `AppDependencies` | JDBC, HTTP dependencies, etc.     |
| `AppTraces`       | Logback and application traces    |
| `AppExceptions`   | Exceptions captured automatically |
| `AppMetrics`      | Micrometer and JVM metrics        |

### Key Environment Variables

| Variable                                         | Purpose                                            |
| ------------------------------------------------ | -------------------------------------------------- |
| `APPLICATIONINSIGHTS_CONNECTION_STRING`          | Azure Application Insights connection string       |
| `APPLICATIONINSIGHTS_SAMPLING_PERCENTAGE`        | Sampling rate (100 for e2e)                        |
| `APPLICATIONINSIGHTS_SELF_DIAGNOSTICS_LEVEL`     | Agent self-diagnostics level                       |
| `APPLICATIONINSIGHTS_SELF_DIAGNOSTICS_FILE_PATH` | Path to self-diagnostics log                       |
| `OTEL_SERVICE_NAME`                              | Service name for Azure Monitor                     |
| `OTEL_RESOURCE_ATTRIBUTES`                       | Additional resource attributes (e.g., environment) |

### Querying Telemetry

Use `az monitor log-analytics query` with workspace customer ID:

```bash
CUSTOM_ID=$(az monitor log-analytics workspace show --resource-group temp-az-1930 --workspace-name task-api-logs-1930 --query customerId -o tsv)

az monitor log-analytics query --workspace "$CUSTOM_ID" \
  --analytics-query 'AppRequests | summarize RequestCount = sum(ItemCount)' \
  --timespan PT30M --output json
```

---

## Troubleshooting

- **No telemetry?** Ensure `APPLICATIONINSIGHTS_SAMPLING_PERCENTAGE=100` for dev tests.
- **Query returns 0 but data exists?** Use `ago(30m)` not `ago(10m)`; ingestion can take 1–3 minutes.
- **JSON parsing?** Use `jq` with both formats:
  `jq -r 'if type=="array" then .[0].RequestCount else .tables[0].rows[0][0] end // 0'`
- **Workspace not linked?** Recreate Application Insights with `--workspace` explicitly.

---

## Security Notes

- Never commit secrets; use Azure Key Vault.
- The JWT secret and DB password are stored in Key Vault.
- The connection string is retrieved at runtime and passed via environment variable.
