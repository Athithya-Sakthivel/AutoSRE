# 1. Create the kind cluster (if not already running)
bash scripts/local/kind_cluster.sh

# 2. Provision Azure storage and the two Kubernetes secrets
#    Creates: openobserve-auth (ZO_ROOT_USER_EMAIL, ZO_ROOT_USER_PASSWORD, OPENOBSERVE_AUTH)
#             openobserve-storage (account-name, account-key)
bash scripts/local/local_secrets.sh

# 3. Deploy OpenObserve
bash scripts/common/open-observe/deploy.sh

# 4. Deploy the OTel gateway (application traces, metrics, logs)
bash scripts/common/otel-gateway-deploy.sh

# 5. Deploy the OTel DaemonSet (node/pod/container metrics)
bash scripts/common/otel-daemonset-deploy.sh

# 6. Verify
kubectl get pods -n openobserve
kubectl get daemonset -n openobserve
kubectl get secrets -n openobserve
