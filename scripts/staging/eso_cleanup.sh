# Delete ALL secrets created by this script
echo "Deleting all ESO-related secrets..."

# Delete ExternalSecrets first
kubectl delete externalsecret --all -n openobserve 2>/dev/null || true
kubectl delete externalsecret --all -n rivulet 2>/dev/null || true
kubectl delete externalsecret --all -n sre 2>/dev/null || true
kubectl delete externalsecret --all -n eval 2>/dev/null || true

# Delete source secret
kubectl delete secret eso-source -n eso-source 2>/dev/null || true

# Delete RBAC
kubectl delete rolebinding eso-k8s-reader-read -n eso-source 2>/dev/null || true
kubectl delete role eso-k8s-reader-read -n eso-source 2>/dev/null || true
kubectl delete serviceaccount eso-k8s-reader -n external-secrets 2>/dev/null || true

# Delete ClusterSecretStore
kubectl delete clustersecretstore eso-k8s-store 2>/dev/null || true

# Wait for cleanup
sleep 5

echo "✓ All secrets deleted. Ready to run script."
