#!/usr/bin/env bash
# ==============================================================================
# Staging Valkey for local Kubernetes clusters.
#
# AZURE COMPATIBILITY & ZERO-CODE-CHANGE DESIGN:
# 1. The App Contract: Apps ONLY read from the 'valkey-app-env' secret.
#    In staging, this script creates it. In prod, External Secrets Operator (ESO)
#    creates it by pulling from Azure Key Vault. The app code never changes.
# 2. TLS Parity: Staging uses plain-text (port 6379, TLS=false) to avoid
#    cert-management overhead in Kind. Prod uses Azure Cache for Redis
#    (port 6380, TLS=true). The app reads VALKEY_TLS_ENABLED to configure its client.
# 3. Storage Parity: Staging uses emptyDir to eliminate local-path-provisioner
#    flakiness and storage costs. Prod uses Azure Premium SSD PVCs. The app
#    doesn't know or care about the storage backend; only the StatefulSet does.
# ==============================================================================

set -Eeuo pipefail
umask 077

NS="${NS:-rivulet}"
# Pinned image digest ensures staging exactly matches prod security scans
VALKEY_IMAGE="${VALKEY_IMAGE:-docker.io/valkey/valkey:9.1.2-alpine@sha256:a0dbf4c1d5708782907c10e2c72deff317518518b5288a58416981d9db95d30b}"

# -----------------------------------------------------------------------------
# HARDCODED STAGING VALUES (Simulates ESO target secret)
# In Prod, ESO injects Azure Cache for Redis values into these exact same keys.
# -----------------------------------------------------------------------------
VALKEY_HOST="valkey.${NS}.svc"
VALKEY_PORT="6379"                  # Prod Azure Cache uses 6380 for TLS
VALKEY_PASS="StagingValkeyP@ss123"  # Hardcoded for staging reproducibility
VALKEY_TLS="false"                  # Prod ESO will inject "true"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# -----------------------------------------------------------------------------
# 1. Server Internal Auth Secret
# Valkey requires passwords in the ACL file to be SHA256 hashed.
# We generate the hash here so the server can enforce strict auth.
# -----------------------------------------------------------------------------
AUTH_SHA256="$(printf %s "$VALKEY_PASS" | sha256sum | cut -d' ' -f1)"
PASSWORD_B64="$(printf %s "$VALKEY_PASS" | base64 | tr -d '\r\n')"
ACL_B64="$(printf 'user default on #%s ~* &* +@all\n' "$AUTH_SHA256" | base64 | tr -d '\r\n')"

kubectl -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: valkey-auth
type: Opaque
data:
  VALKEY_PASSWORD: "${PASSWORD_B64}"
  users.acl: "${ACL_B64}"
EOF

# -----------------------------------------------------------------------------
# 2. APP CONTRACT SECRET
# This is the exact structure ESO will generate in Prod.
# Apps mount this secret via envFrom or valueFrom.
# -----------------------------------------------------------------------------
kubectl -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: valkey-app-env
  labels:
    autosre.io/contract: app-env
type: Opaque
stringData:
  VALKEY_HOST: "${VALKEY_HOST}"
  VALKEY_PORT: "${VALKEY_PORT}"
  VALKEY_PASSWORD: "${VALKEY_PASS}"
  VALKEY_TLS_ENABLED: "${VALKEY_TLS}"
EOF

# -----------------------------------------------------------------------------
# 3. Deploy Valkey Server (StatefulSet)
# -----------------------------------------------------------------------------
kubectl -n "$NS" apply -f - <<EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: valkey
spec:
  serviceName: valkey-headless
  replicas: 1
  selector:
    matchLabels:
      app: valkey
  template:
    metadata:
      labels:
        app: valkey
    spec:
      terminationGracePeriodSeconds: 120
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: valkey
          image: "${VALKEY_IMAGE}"
          command:
            - valkey-server
          args:
            - --bind
            - "0.0.0.0"
            - --port
            - "${VALKEY_PORT}"
            - --protected-mode
            - "yes"
            - --aclfile
            - /etc/valkey/users.acl
            - --dir
            - /data
            - --appendonly
            - "yes"
            - --appendfsync
            - everysec
            - --tcp-keepalive
            - "60"
          ports:
            - name: client
              containerPort: ${VALKEY_PORT}
          env:
            # SRE PATTERN: valkey-cli natively reads VALKEYCLI_AUTH.
            # This allows probes to authenticate without putting passwords in the
            # YAML command array, avoiding bash/YAML escaping nightmares.
            - name: VALKEYCLI_AUTH
              valueFrom:
                secretKeyRef:
                  name: valkey-auth
                  key: VALKEY_PASSWORD
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          resources:
            # Staging minimum viable prod spec. Prod scales via VPA/HPA.
            requests:
              cpu: "500m"
              memory: "0.5Gi"
            limits:
              cpu: "1"
              memory: "1Gi"
          # Explicit probes (no YAML anchors) to prevent kubectl parsing edge cases.
          startupProbe:
            exec:
              command:
                - valkey-cli
                - --no-auth-warning
                - PING
            failureThreshold: 60
            periodSeconds: 5
          readinessProbe:
            exec:
              command:
                - valkey-cli
                - --no-auth-warning
                - PING
            failureThreshold: 3
            periodSeconds: 5
          livenessProbe:
            exec:
              command:
                - valkey-cli
                - --no-auth-warning
                - PING
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 6
          volumeMounts:
            - name: data
              mountPath: /data
            - name: auth
              mountPath: /etc/valkey
              readOnly: true
      volumes:
        # Staging: emptyDir eliminates PVC provisioning latency and costs.
        # Prod: ESO/Kustomize overlays replace this with a PVC template.
        - name: data
          emptyDir:
            sizeLimit: "10Gi"
        - name: auth
          secret:
            secretName: valkey-auth
            defaultMode: 0440
            items:
              - key: users.acl
                path: users.acl
---
apiVersion: v1
kind: Service
metadata:
  name: valkey-headless
spec:
  clusterIP: None
  selector:
    app: valkey
  ports:
    - name: client
      port: ${VALKEY_PORT}
---
apiVersion: v1
kind: Service
metadata:
  name: valkey
spec:
  selector:
    app: valkey
  ports:
    - name: client
      port: ${VALKEY_PORT}
EOF

kubectl -n "$NS" rollout status statefulset/valkey --timeout=300s
echo " Valkey ready. App contract secret 'valkey-app-env' created."
