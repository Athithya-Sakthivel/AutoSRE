#!/usr/bin/env bash
# Staging PostgreSQL for local Kind clusters.
# Replaces Azure Flexible Server to eliminate staging DB cost.
# Uses the official postgres:16.15-trixie image for AKS/Azure version parity.

set -Eeuo pipefail

NS="${NS:-rivulet}"
IMAGE="${IMAGE:-docker.io/library/postgres:18.4-trixie@sha256:3a82e1f56c8f0f5616a11103ac3d47e632c3938698946a7ad26da0df1334744a}"

# HARDCODED STAGING VALUES (Simulates ESO target secret)
PG_HOST="postgres.${NS}.svc"
PG_PORT="5432"
PG_DB="app"
PG_USER="app"
PG_PASS="StagingPostgresP@ss123"
PG_SSLMODE="disable"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# 1. Create the APP CONTRACT SECRET (Exactly what ESO creates in Prod)
kubectl -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: postgres-app-env
  labels:
    autosre.io/contract: app-env
type: Opaque
stringData:
  PGHOST: "${PG_HOST}"
  PGPORT: "${PG_PORT}"
  PGDATABASE: "${PG_DB}"
  PGUSER: "${PG_USER}"
  PGPASSWORD: "${PG_PASS}"
  PGSSLMODE: "${PG_SSLMODE}"
EOF

# 2. Deploy PostgreSQL Server
kubectl -n "$NS" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
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
            - name: POSTGRES_DB
              valueFrom:
                secretKeyRef:
                  name: postgres-app-env
                  key: PGDATABASE
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: postgres-app-env
                  key: PGUSER
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-app-env
                  key: PGPASSWORD
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          ports:
            - name: postgres
              containerPort: 5432
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          # Note: \$ escapes the variable from Bash so K8s evaluates it from pod env.
          # Single quotes in YAML prevent YAML from trying to parse \$ as an escape sequence.
          readinessProbe:
            exec:
              command:
                - sh
                - '-c'
                - 'pg_isready -U \$PGUSER -d \$PGDATABASE'
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 6
          livenessProbe:
            exec:
              command:
                - sh
                - '-c'
                - 'pg_isready -U \$PGUSER -d \$PGDATABASE'
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 6
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
spec:
  selector:
    app: postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: postgres
EOF

kubectl -n "$NS" rollout status deploy/postgres --timeout=180s
echo " PostgreSQL ready. App contract secret 'postgres-app-env' created."
