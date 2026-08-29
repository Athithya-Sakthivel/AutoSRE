#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Argo Rollouts + Gateway API plugin + ESO for local kind.
# Assumes bootstrap.sh already installed Cilium with Gateway API.

# Version must include leading 'v' (e.g. v1.9.1)
ARGO_ROLLOUTS_VERSION="${ARGO_ROLLOUTS_VERSION:-v1.9.1}"
ARGO_ROLLOUTS_CHART_VERSION="${ARGO_ROLLOUTS_CHART_VERSION:-2.41.1}"
GATEWAY_API_PLUGIN_VERSION="${GATEWAY_API_PLUGIN_VERSION:-v0.16.0}"
ARGO_NAMESPACE="${ARGO_NAMESPACE:-argo-rollouts}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"

GATEWAY_PLUGIN_IMAGE="ghcr.io/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi:${GATEWAY_API_PLUGIN_VERSION}"

ESO_VERSION="2.8.0"
ESO_NAMESPACE="external-secrets"

TMP_DIR="$(mktemp -d)"
VALUES_FILE="${TMP_DIR}/values.yaml"

log() { printf '==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

cleanup_argo() {
  log "Removing existing Argo Rollouts"
  helm uninstall argo-rollouts -n "${ARGO_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete namespace "${ARGO_NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
}

verify_gateway_api() {
  log "Verifying Gateway API prerequisites"
  for crd in gateways httproutes referencegrants backendtlspolicies; do
    kubectl get crd "${crd}.gateway.networking.k8s.io" >/dev/null 2>&1 ||
      die "Gateway API CRD ${crd} not found; run bootstrap.sh first"
  done
  kubectl get gatewayclass cilium >/dev/null 2>&1 ||
    die "GatewayClass cilium not found"
}

write_values() {
  cat >"${VALUES_FILE}" <<YAML
controller:
  image:
    registry: quay.io
    repository: argoproj/argo-rollouts
    tag: ${ARGO_ROLLOUTS_VERSION}
  initContainers:
    - name: copy-gateway-api-plugin
      image: ${GATEWAY_PLUGIN_IMAGE}
      imagePullPolicy: IfNotPresent
      command:
        - /bin/sh
        - -c
      args:
        - cp /bin/rollouts-plugin-trafficrouter-gatewayapi /plugins/rollouts-plugin-trafficrouter-gatewayapi
      volumeMounts:
        - name: gateway-api-plugin
          mountPath: /plugins

  trafficRouterPlugins:
    - name: argoproj-labs/gatewayAPI
      location: file:///plugins/rollouts-plugin-trafficrouter-gatewayapi

  volumes:
    - name: gateway-api-plugin
      emptyDir: {}

  volumeMounts:
    - name: gateway-api-plugin
      mountPath: /plugins

providerRBAC:
  enabled: true
  providers:
    gatewayAPI: true
YAML
}

install_argo() {
  log "Adding Argo Helm repo"
  helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
  helm repo update >/dev/null

  write_values

  log "Installing Argo Rollouts ${ARGO_ROLLOUTS_VERSION}"
  helm upgrade --install argo-rollouts argo/argo-rollouts \
    --namespace "${ARGO_NAMESPACE}" \
    --create-namespace \
    --version "${ARGO_ROLLOUTS_CHART_VERSION}" \
    --values "${VALUES_FILE}" \
    --wait --timeout "${WAIT_TIMEOUT}s"

  kubectl rollout status deployment/argo-rollouts -n "${ARGO_NAMESPACE}" --timeout="${WAIT_TIMEOUT}s"
}

verify_plugin() {
  log "Verifying Gateway API plugin"
  kubectl get configmap argo-rollouts-config -n "${ARGO_NAMESPACE}" -o yaml |
    grep -q 'argoproj-labs/gatewayAPI' ||
    die "Plugin not found in argo-rollouts-config"
  log "Argo Rollouts Gateway API plugin verified"
}

main() {
  require_cmd kubectl
  require_cmd helm
  require_cmd grep

  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot connect to cluster"

  cleanup_argo
  verify_gateway_api
  install_argo
  verify_plugin

  log "Argo Rollouts setup complete"
  kubectl get pods -n "${ARGO_NAMESPACE}" -o wide

  helm repo add external-secrets https://charts.external-secrets.io
  helm repo update

  helm upgrade --install external-secrets \
    external-secrets/external-secrets \
    --namespace "${ESO_NAMESPACE}" \
    --create-namespace \
    --version "${ESO_VERSION}" \
    --set image.tag="v${ESO_VERSION}" \
    --wait

  helm list -n external-secrets

  kubectl get pods -n external-secrets

  kubectl get crd | grep external-secrets.io

}

main "$@"
