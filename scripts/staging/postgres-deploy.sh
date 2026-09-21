#!/usr/bin/env bash
# ==============================================================================
# Staging PostgreSQL for local kind clusters.
#
# Design
# ------
# The app contract Secret `postgres-app` is owned by ESO (see
# scripts/staging/eso_local.sh). This script:
#
#   1. Waits for ESO to materialise `postgres-app` in the target namespace.
#   2. Deploys the PostgreSQL server, sourcing credentials from that Secret.
#   3. Exposes the server as postgres.<ns>.svc:5432.
#
# There is no separate staging contract Secret. The server and the
# applications read from the same ESO-managed Secret, so a password rotation
# in eso-source/eso-source propagates everywhere without further action.
#
# Storage is emptyDir. Data does not survive pod deletion. This is intentional
# for local development and evaluation.
# ==============================================================================

set -Eeuo pipefail

NS="${NS:-rivulet}"
IMAGE="${IMAGE:-docker.io/library/postgres:18.4-trixie@sha256:3a82e1f56c8f0f5616a11103ac3d47e632c3938698946a7ad26da0df1334744a}"
CONTRACT_SECRET="${CONTRACT_SECRET:-postgres-app}"
WAIT_SECRET_TIMEOUT="${WAIT_SECRET_TIMEOUT:-120}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || die "kubectl not found"

# -----------------------------------------------------------------------------
# 1. Ensure namespace exists
# -----------------------------------------------------------------------------
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# -----------------------------------------------------------------------------
# 2. Wait for the ESO-managed app contract Secret
# -----------------------------------------------------------------------------
log "waiting for Secret ${NS}/${CONTRACT_SECRET} (created by ESO)"
elapsed=0
until kubectl -n "$NS" get secret "$CONTRACT_SECRET" >/dev/null 2>&1; do
  if (( elapsed >= WAIT_SECRET_TIMEOUT )); then
    die "Secret ${NS}/${CONTRACT_SECRET} did not appear within ${WAIT_SECRET_TIMEOUT}s.
     Run scripts/staging/eso_local.sh first."
  fi
  sleep 2
  elapsed=$(( elapsed + 2 ))
done

for key in username password dbname; do
  if ! kubectl -n "$NS" get secret "$CONTRACT_SECRET" \
       -o "jsonpath={.data.${key}}" 2>/dev/null | grep -q .; then
    die "Secret ${NS}/${CONTRACT_SECRET} is missing key '${key}'"
  fi
done
log "contract Secret present: ${NS}/${CONTRACT_SECRET}"

# -----------------------------------------------------------------------------
# 3. Deploy PostgreSQL server
# -----------------------------------------------------------------------------
log "applying Deployment/postgres and Service/postgres"
kubectl -n "$NS" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  labels:
    app: postgres
    app.kubernetes.io/name: postgres
    app.kubernetes.io/part-of: rivulet
    app.kubernetes.io/component: datastore
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
        app.kubernetes.io/name: postgres
        app.kubernetes.io/part-of: rivulet
        app.kubernetes.io/component: datastore
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: postgres
          image: "${IMAGE}"
          imagePullPolicy: IfNotPresent
          env:
            # Consumed by docker-entrypoint.sh during initdb.
            - name: POSTGRES_DB
              valueFrom:
                secretKeyRef:
                  name: ${CONTRACT_SECRET}
                  key: dbname
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: ${CONTRACT_SECRET}
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${CONTRACT_SECRET}
                  key: password
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
            # libpq defaults for in-pod tooling.
            # These make bare \`psql\`, \`pg_dump\`, \`pg_isready\` work without
            # flags. PGHOST is intentionally not set so libpq uses the local
            # Unix socket instead of hairpinning through the Service.
            - name: PGUSER
              valueFrom:
                secretKeyRef:
                  name: ${CONTRACT_SECRET}
                  key: username
            - name: PGDATABASE
              valueFrom:
                secretKeyRef:
                  name: ${CONTRACT_SECRET}
                  key: dbname
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${CONTRACT_SECRET}
                  key: password
          ports:
            - name: postgres
              containerPort: 5432
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          # Bare pg_isready reads PGUSER / PGDATABASE / PGPASSWORD from env.
          # No shell wrapper, no quoting pitfalls.
          readinessProbe:
            exec:
              command: ["pg_isready"]
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 6
          livenessProbe:
            exec:
              command: ["pg_isready"]
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 6
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "1"
              memory: "1Gi"
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: data
          emptyDir:
            sizeLimit: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  labels:
    app: postgres
    app.kubernetes.io/name: postgres
    app.kubernetes.io/part-of: rivulet
    app.kubernetes.io/component: datastore
spec:
  selector:
    app: postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: postgres
EOF

# -----------------------------------------------------------------------------
# 4. Wait for readiness
# -----------------------------------------------------------------------------
log "waiting for Deployment/postgres rollout"
kubectl -n "$NS" rollout status deploy/postgres --timeout=180s

# -----------------------------------------------------------------------------
# 5. Smoke test
# -----------------------------------------------------------------------------
log "smoke test: SELECT 1 via unix socket (bare psql)"
if ! kubectl -n "$NS" exec deploy/postgres -- psql -Atqc 'SELECT 1' >/dev/null; then
  die "psql smoke test failed"
fi

log "postgres ready at postgres.${NS}.svc:5432"
log "app contract: Secret ${NS}/${CONTRACT_SECRET} (managed by ESO)"
