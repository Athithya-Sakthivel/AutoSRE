set -euo pipefail

CLUSTER=kind
K8S_IMAGE=docker.io/kindest/node:v1.32.2@sha256:142f543559cc55d64e1ab9341df08e5ced84bd2e893736da8f51320f26f5950b
ARGO_VERSION=v1.9.1

# kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
kind create cluster --name "$CLUSTER" --image "$K8S_IMAGE" --wait 5m
kind export kubeconfig --name "$CLUSTER"

kubectl wait --for=condition=Ready nodes --all --timeout=5m

kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argo-rollouts -f "https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_VERSION}/install.yaml"

kubectl rollout status deployment/argo-rollouts -n argo-rollouts --timeout=5m
kubectl wait --for=condition=Established crd/rollouts.argoproj.io --timeout=2m

kubectl get nodes
kubectl get pods -n argo-rollouts
kubectl get crd rollouts.argoproj.io

echo "READY: Kind + Argo Rollouts ${ARGO_VERSION}"