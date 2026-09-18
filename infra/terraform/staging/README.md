# Database & Cache Environment Contracts

This document defines the **Zero-Code-Change** contract for connecting Rivulet services to PostgreSQL and Valkey across Staging (Kind) and Production (Azure AKS) environments.

## The Core Rule
Applications **must never** hardcode hosts, ports, or construct connection URIs from raw strings in configuration files. Applications must read **discrete environment variables** injected via Kubernetes Secrets.

This ensures that moving from Staging to Production requires zero application code or Helm chart changes; only the underlying Secret generator changes.

## 1. The Kubernetes Secret Contract

Applications mount these exact Secret names and keys.

### `postgres-app-env` (Namespace: `rivulet`)
| Key | Type | Description |
| :--- | :--- | :--- |
| `PGHOST` | String | Database hostname or IP. |
| `PGPORT` | String | Database port (e.g., `"5432"`). |
| `PGDATABASE`| String | Database name. |
| `PGUSER` | String | Authentication username. |
| `PGPASSWORD`| String | Authentication password. |
| `PGSSLMODE` | String | TLS enforcement (`disable` in staging, `require` in prod). |

### `valkey-app-env` (Namespace: `rivulet`)
| Key | Type | Description |
| :--- | :--- | :--- |
| `VALKEY_HOST` | String | Cache hostname or IP. |
| `VALKEY_PORT` | String | Cache port (`"6379"` in staging, `"6380"` in prod). |
| `VALKEY_PASSWORD`| String | Authentication password. |
| `VALKEY_TLS_ENABLED`| String | Boolean string (`"false"` in staging, `"true"` in prod). |

## 2. Environment Parity Matrix

| Variable | Staging (Kind) Source | Production (AKS) Source |
| :--- | :--- | :--- |
| **Secret Generator** | `scripts/staging/postgres-deploy.sh` | External Secrets Operator (ESO) |
| **PGHOST** | `postgres.rivulet.svc` | Azure Flexible Server DNS |
| **PGSSLMODE** | `disable` | `require` |
| **VALKEY_HOST** | `valkey.rivulet.svc` | Azure Cache for Redis DNS |
| **VALKEY_PORT** | `6379` | `6380` (TLS Port) |
| **VALKEY_TLS_ENABLED**| `false` | `true` |

## 3. Azure Key Vault Mapping (Production)

In production, ESO reads discrete secrets from Azure Key Vault to populate the Kubernetes Secrets above. Key Vault names strictly use letters, digits, and dashes.

| K8s Secret Key | Azure Key Vault Secret Name |
| :--- | :--- |
| `PGHOST` | `pg-rivulet-host` |
| `PGPORT` | `pg-rivulet-port` |
| `PGDATABASE` | `pg-rivulet-db` |
| `PGUSER` | `pg-rivulet-user` |
| `PGPASSWORD` | `pg-rivulet-pass` |
| `VALKEY_HOST` | `valkey-rivulet-host` |
| `VALKEY_PORT` | `valkey-rivulet-port` |
| `VALKEY_PASSWORD` | `valkey-rivulet-pass` |
| `VALKEY_TLS_ENABLED`| `valkey-rivulet-tls` |

## 4. Why We Killed Derived URIs

Previous iterations of this infrastructure generated full connection strings in bash/Terraform (e.g., `postgresql://user:pass@host:5432/db`). **This was an anti-pattern and has been removed.**

1. **URL Encoding Bugs:** If a generated password contains `@`, `:`, or `/`, the resulting URI breaks unless perfectly URL-encoded. Native drivers (JDBC, pgx, go-redis) handle discrete variables safely without manual encoding.
2. **Dual Source of Truth:** Maintaining both discrete variables and a concatenated URI leads to configuration drift.
3. **Driver Optimization:** Native drivers often require discrete parameters to properly configure connection pools, SSL contexts, and timeouts.

## 5. Application Integration Examples

### Java (Spring Boot / HikariCP)
```yaml
spring:
  datasource:
    # Let the JDBC driver assemble the URL from discrete env vars
    url: jdbc:postgresql://${PGHOST}:${PGPORT}/${PGDATABASE}?sslmode=${PGSSLMODE}
    username: ${PGUSER}
    password: ${PGPASSWORD}
```

### Go (pgx / go-redis)
```go
// Postgres
cfg, _ := pgx.ParseConfig(os.Getenv("DATABASE_URL")) // Optional
// OR preferred discrete:
cfg.Host = os.Getenv("PGHOST")
cfg.Port = parseUint16(os.Getenv("PGPORT"))
cfg.Database = os.Getenv("PGDATABASE")
cfg.User = os.Getenv("PGUSER")
cfg.Password = os.Getenv("PGPASSWORD")

// Valkey
tlsEnabled, _ := strconv.ParseBool(os.Getenv("VALKEY_TLS_ENABLED"))
rdb := redis.NewClient(&redis.Options{
    Addr:     os.Getenv("VALKEY_HOST") + ":" + os.Getenv("VALKEY_PORT"),
    Password: os.Getenv("VALKEY_PASSWORD"),
    TLSConfig: func() *tls.Config {
        if tlsEnabled { return &tls.Config{ServerName: os.Getenv("VALKEY_HOST")} }
        return nil
    }(),
})
```
```
