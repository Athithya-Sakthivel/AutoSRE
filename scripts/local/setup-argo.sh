#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Argo Rollouts + Gateway API traffic‑routing plugin setup.
#
# Assumes:
#   - Gateway API CRDs are already installed (setup-istio.sh)
#   - Helm is available
#
# This script:
#   - Cleans up any existing Argo Rollouts installation
#   - Verifies Gateway API CRDs exist
#   - Installs Argo Rollouts using the official Helm chart
#   - Adds the Gateway API plugin as an init container
#   - Verifies the installation
#
# Run after setup-istio.sh.

ARGO_ROLLOUTS_VERSION="${ARGO_ROLLOUTS_VERSION:-1.9.1}"
ARGO_ROLLOUTS_CHART_VERSION="${ARGO_ROLLOUTS_CHART_VERSION:-2.41.1}"
GATEWAY_API_PLUGIN_VERSION="${GATEWAY_API_PLUGIN_VERSION:-v0.16.0}"
ARGO_NAMESPACE="${ARGO_NAMESPACE:-argo-rollouts}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"

log() { printf '==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

cleanup_argo() {
  log "Cleaning up existing Argo Rollouts (if any)"
  if helm status argo-rollouts -n "${ARGO_NAMESPACE}" >/dev/null 2>&1; then
    helm uninstall argo-rollouts -n "${ARGO_NAMESPACE}" || true
  fi
  kubectl delete namespace "${ARGO_NAMESPACE}" --ignore-not-found=true
}

verify_gateway_api() {
  log "Verifying Gateway API CRDs"
  kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1 ||
    die "Gateway API HTTPRoute CRD not found. Run setup-istio.sh first."
  kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 ||
    die "Gateway API Gateway CRD not found. Run setup-istio.sh first."
}

install_argo() {
  log "Adding Argo Helm repository"
  helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
  helm repo update >/dev/null

  log "Generating Argo Rollouts Helm values"
  local values_file
  values_file="$(mktemp)"
  cat >"${values_file}" <<YAML
controller:
  initContainers:
    - name: copy-gwapi-plugin
      image: ghcr.io/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi:${GATEWAY_API_PLUGIN_VERSION}
      command:
        - /bin/sh
        - -c
      args:
        - >
          cp /bin/rollouts-plugin-trafficrouter-gatewayapi
          /plugins/rollouts-plugin-trafficrouter-gatewayapi
      volumeMounts:
        - name: gwapi-plugin
          mountPath: /plugins

  trafficRouterPlugins:
    - name: argoproj-labs/gatewayAPI
      location: file:///plugins/rollouts-plugin-trafficrouter-gatewayapi

  volumes:
    - name: gwapi-plugin
      emptyDir: {}

  volumeMounts:
    - name: gwapi-plugin
      mountPath: /plugins

providerRBAC:
  enabled: true
  providers:
    gatewayAPI: true
YAML

  log "Installing Argo Rollouts ${ARGO_ROLLOUTS_VERSION} using Helm chart ${ARGO_ROLLOUTS_CHART_VERSION}"
  helm upgrade --install argo-rollouts argo/argo-rollouts \
    --namespace "${ARGO_NAMESPACE}" \
    --create-namespace \
    --version "${ARGO_ROLLOUTS_CHART_VERSION}" \
    --set-string "image.tag=${ARGO_ROLLOUTS_VERSION}" \
    --values "${values_file}" \
    --wait \
    --timeout "${WAIT_TIMEOUT}"

  kubectl rollout status deployment/argo-rollouts -n "${ARGO_NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
}

verify_plugin() {
  log "Verifying Argo Rollouts Gateway API plugin"

  kubectl get configmap argo-rollouts-config -n "${ARGO_NAMESPACE}" -o yaml |
    grep -q 'argoproj-labs/gatewayAPI' ||
    die "argo-rollouts-config does not contain the Gateway API plugin"

  kubectl get deployment argo-rollouts -n "${ARGO_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.initContainers[*].image}' |
    grep -Fq "${GATEWAY_API_PLUGIN_VERSION}" ||
    die "Argo Rollouts Deployment does not contain plugin image ${GATEWAY_API_PLUGIN_VERSION}"

  log "Argo Rollouts Gateway API plugin verified"
}

main() {
  require_cmd kubectl
  require_cmd helm

  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot connect to the cluster"

  cleanup_argo
  verify_gateway_api
  install_argo
  verify_plugin

  log "Argo Rollouts setup complete."
  kubectl get pods -n "${ARGO_NAMESPACE}" -o wide
}

main "$@"