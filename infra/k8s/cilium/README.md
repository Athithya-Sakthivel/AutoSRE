# AutoSRE Cilium NetworkPolicies — Final Reference

**Zero-trust network isolation for the AutoSRE evaluation platform.**

This Helm chart manages the complete CiliumNetworkPolicy layer. It does **not** install Cilium itself — Cilium is provisioned separately as the cluster CNI via `scripts/staging/kind_cluster.sh`. This chart applies only the policy resources that enforce least-privilege connectivity.

---

## The Five Rules That Prevent All Known Policy Bugs

Every outage this system has produced traces to violating one of these rules. Read them before writing or modifying any policy.

### Rule 1 — `k8s:` prefix is mandatory on Kubernetes labels

Cilium stores Kubernetes labels internally with a `k8s:` prefix. Namespace selectors **must** use it:

```yaml
# WRONG — matches zero endpoints, silent SYN drop
matchLabels:
  io.kubernetes.pod.namespace: rivulet

# RIGHT
matchLabels:
  k8s:io.kubernetes.pod.namespace: rivulet
```

Application labels (`app.kubernetes.io/*`, `app`) work without the prefix. Only `io.kubernetes.pod.namespace` requires it. Failure mode: silent TCP timeout (~2 min), no RST, no error message.

### Rule 2 — Default-deny needs a never-matching rule, not empty arrays

Empty `ingress: []` / `egress: []` does **not** enable isolation in Cilium. Use the sentinel label idiom:

```yaml
spec:
  endpointSelector: {}
  ingress:
    - fromEndpoints:
        - matchLabels:
            cilium.io/no-such-entity: "true"
  egress:
    - toEndpoints:
        - matchLabels:
            cilium.io/no-such-entity: "true"
```

**Never use `ingressDeny` / `egressDeny: fromEntities: [all]`** as a default-deny mechanism. Deny rules are hard vetoes that override every allow rule in the namespace.

### Rule 3 — Both egress AND ingress must allow the flow

Under default-deny, a flow requires permission on **both** endpoints:

- Source's egress allows the destination ✅
- Destination's ingress allows the source ✅

Writing only one side produces a TCP timeout identical to a missing rule. Every cross-service flow is a **pair** of policies. When adding a new client, check the destination's ingress. When adding a new destination, create its ingress policy.

### Rule 4 — Kubelet probes come from the host entity

Liveness, readiness, and startup probes originate in the node's network namespace, not from a pod IP. Without an explicit rule, every probe is dropped and pods crash-loop:

```yaml
ingress:
  - fromEntities:
      - host
      - remote-node
    toPorts:
      - ports:
          - port: "8080"
            protocol: TCP
```

Include `remote-node` for multi-node clusters where kubelet runs on a different node than the pod.

### Rule 5 — Image tags must be unique per build

Using git SHA alone as an image tag causes Kind's containerd to reuse cached images when code changes aren't committed. Use timestamp-based tags:

```
YYYY-MM-DD-HH-MM-SS--<git-sha>
```

This guarantees uniqueness per build regardless of commit state. Combined with `imagePullPolicy: IfNotPresent`, Kubernetes always loads the correct image.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        KIND CLUSTER                                  │
│                                                                      │
│  kube-system: Cilium (CNI + kube-proxy replacement)                  │
│  kube-system: CoreDNS (upstream: 8.8.8.8 + 1.1.1.1)                │
│                                                                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌────────┐  │
│  │   rivulet    │  │     sre      │  │     eval     │  │openobs.│  │
│  │              │  │              │  │              │  │        │  │
│  │ api-gateway  │←→│ autosre-agent│←→│ fault-runner │  │openobs.│  │
│  │ frontend     │  │              │  │ deepeval     │  │otel-gw │  │
│  │ ingest-worker│  │              │  │              │  │otel-ds │  │
│  │ postgres     │  │              │  │ postgres     │  │        │  │
│  │ valkey       │  │              │  │              │  │        │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  └────────┘  │
│                                                                      │
│         All traffic governed by Cilium default-deny + allow rules    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Namespace Topology

| Namespace | Workloads | Ports | Role |
|-----------|-----------|-------|------|
| `rivulet` | postgres, valkey, api-gateway, ingestion-worker, frontend | 5432, 6379, 8080, 8081 | System Under Test |
| `sre` | autosre-agent | 8000 | Autonomous remediation |
| `eval` | fault-runner jobs, deepeval harness | ephemeral | Evaluation |
| `openobserve` | openobserve, otel-gateway, otel-daemonset | 5080, 4317, 4318 | Observability |
| `kube-system` | coredns, kube-apiserver | 53, 6443 | Cluster control plane |

Default-deny applies to all four workload namespaces. `kube-system` is not isolated (Cilium and CoreDNS require unrestricted access).

---

## Policy Files

Each file has one bounded responsibility. Policies are additive — Cilium uses an allow-union model.

| File | CNP Name(s) | Direction | Purpose |
|------|-------------|-----------|---------|
| `00-default-deny.yaml` | `default-deny` | both | Zero-trust baseline in all 4 workload namespaces |
| `01-allow-dns-egress.yaml` | `allow-dns-egress` | egress | DNS resolution via kube-dns:53 with L7 interception. All 4 namespaces |
| `02-rivulet-internal.yaml` | `api-gateway-ingress`, `frontend-ingress` | ingress | Frontend → api-gateway:8080; external → frontend:8080; kubelet probes |
| `03-rivulet-to-datastores.yaml` | `clients-to-datastores-egress`, `postgres-ingress`, `valkey-ingress` | egress+ingress | api-gateway/ingestion-worker ↔ postgres:5432, valkey:6379. Agent also allowed. Valkey matched by `app: valkey` |
| `04-rivulet-to-otel.yaml` | `rivulet-to-otel` | egress | All rivulet pods → otel-gateway:4318 |
| `05-eval-to-chaos-ports.yaml` | `eval-egress` | egress | eval → rivulet backend:8081 (chaos), sre:8000, openobserve:5080, world:443. Chaos scoped to `component: backend` |
| `06-sre-agent-egress.yaml` | `sre-agent-egress` | egress | Agent → kube-apiserver:6443, postgres:5432, valkey:6379, openobserve:5080, otel-gw:4318, world:443. Includes `toCIDR: 172.18.0.0/16` Kind fallback for apiserver |
| `07-sre-agent-ingress.yaml` | `openobserve-ingress`, `sre-agent-ingress` | ingress | openobserve ← agent/eval/otel-gw/host; agent ← openobserve webhooks/eval/host |
| `08-ingestion-worker-ingress.yaml` | `ingestion-worker-ingress` | ingress | Kubelet probes:8080, eval chaos:8081 |
| `09-eval-internal.yaml` | `eval-to-internal-postgres`, `eval-postgres-ingress` | egress+ingress | Eval pods ↔ ground-truth postgres:5432 within eval namespace |
| `10-openobserve-internal.yaml` | `otel-daemonset-to-gateway`, `otel-gateway-to-openobserve`, `otel-gateway-ingress`, `otel-daemonset-ingress` | egress+ingress | Full observability pipeline: daemonset → gateway → openobserve. Smoke test pods allowed on 4317+4318 |
| `11-openobserve-egress.yaml` | `openobserve-egress` | egress | openobserve → agent:8000 (webhooks), world:443/587 (Slack/SMTP) |
| `12-frontend-egress.yaml` | `frontend-egress` | egress | Frontend → api-gateway:8080 |

All files are guarded by `{{- if .Values.networkPolicies.enabled }}`.

---

## Security Invariants

These are non-negotiable guarantees. Violation means the evaluation harness is compromised.

1. **Chaos port isolation.** TCP/8081 reachable only from `eval` namespace. No other namespace or external source can trigger chaos.
2. **Agent cannot self-inject faults.** `sre` has no egress to port 8081. Agent observes and remediates but never triggers chaos.
3. **Datastore access is role-scoped.** Only api-gateway, ingestion-worker, and autosre-agent reach postgres/valkey. Frontend cannot bypass the API.
4. **Agent egress is explicitly enumerated.** Exactly 6 destinations: kube-apiserver, postgres, valkey, openobserve, otel-gateway, world:443.
5. **DNS is intercepted.** `allow-dns-egress` uses `rules.dns` with `matchPattern: "*"` for L7 visibility.
6. **Every destination has explicit ingress.** No implicit trust between namespaces.
7. **Kubelet probes from host entity only.** Not spoofable from pods.

---

## Deployment

```bash
# Apply/update all policies
helm upgrade --install autosre-cilium infra/k8s/cilium/ \
  --namespace kube-system --wait --timeout 120s

# Verify all VALID=True
kubectl get cnp -A -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,VALID:.status.conditions[?(@.type=="Valid")].status'

# Uninstall (removes all policies, reverts to unrestricted)
helm uninstall autosre-cilium --namespace kube-system
```

---

## Verification Commands

### Confirm isolation is active
```bash
kubectl get cep -n rivulet    # Every pod must have a CiliumEndpoint
kubectl get cep -n sre
kubectl get cep -n eval
kubectl get cep -n openobserve
```

### Test chaos port isolation
```bash
RIV_IP=$(kubectl get pod -n rivulet -l app.kubernetes.io/name=api-gateway \
  -o jsonpath='{.items[0].status.podIP}')

# From eval — SUCCEEDS
kubectl run test-ok -n eval --rm -it --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}\n" -X POST "http://${RIV_IP}:8081/__chaos/reset"

# From rivulet — TIMES OUT (correct behavior)
kubectl run test-bad -n rivulet --rm -it --image=curlimages/curl -- \
  curl -s --connect-timeout 5 -X POST "http://${RIV_IP}:8081/__chaos/reset"
```

Timeout = policy working. Connection refused (RST) = policy broken.

### Debug blocked traffic with drop monitor
```bash
NODE=$(kubectl get pod <pod-name> -n <ns> -o jsonpath='{.spec.nodeName}')
CILIUM=$(kubectl get pods -n kube-system -l k8s-app=cilium \
  --field-selector spec.nodeName="$NODE" \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n kube-system "$CILIUM" -c cilium-agent -- \
  cilium-dbg monitor --type drop
```

Drop at `bpf_lxc.c:1651` = egress denied on source pod.
Drop at `bpf_lxc.c:2405` = ingress denied on destination pod.

---

## Adding a New Service Checklist

1. Label pod template with `app.kubernetes.io/name: <service>`
2. Pod is automatically isolated by namespace-wide default-deny
3. Write ingress CNP if anything needs to reach it (include kubelet probe rule)
4. Add egress rules to appropriate existing CNP or create new one
5. **Add BOTH sides** (egress on source + ingress on destination) in the same change
6. Update deploy script preflight `REQUIRED_CNPS` list
7. Verify with `kubectl get cnp -A` (VALID=True) and `kubectl get cep`

## Adding a New Flow Checklist

1. Get exact labels: `kubectl get pod <dest> --show-labels`
2. Add source to destination's ingress CNP
3. Add destination to source's egress CNP
4. Submit both changes together
5. Test with drop monitor running — zero `Policy denied` lines = correct

---

## Known Bugs and Their Fixes

| # | Bug | Symptom | Root Cause | Fix |
|---|-----|---------|------------|-----|
| 1 | Missing `k8s:` prefix | Init container hangs ~2min, no drops on source node | Selector matches zero endpoints | Always prefix `io.kubernetes.pod.namespace` with `k8s:` |
| 2 | `ingressDeny` as default-deny | All allow rules silently ignored | Deny overrides allow unconditionally | Use never-matching sentinel label idiom |
| 3 | Egress-only policy | TCP timeout, drops only visible on dest node | Missing ingress on destination | Always write both sides |
| 4 | Missing kubelet probe rule | Pod crash-loops, 0/1 Ready forever | Probes from host entity, not pod | Add `fromEntities: [host, remote-node]` |
| 5 | Empty arrays for default-deny | CNP valid but nothing isolated | Empty arrays don't enable isolation | Use never-matching rule |
| 6 | Stale image cache | Old code runs despite rebuild | Same tag + IfNotPresent = cached | Timestamp-based tags (`YYYY-MM-DD-HH-MM-SS--sha`) |
| 7 | CoreDNS upstream failure | All external DNS fails, `[Errno -3]` | WSL2/Docker has no DNS at 172.18.0.1:53 | Patch CoreDNS to forward to 8.8.8.8 + 1.1.1.1 |
| 8 | kube-proxy + Cilium dual-mode | Service routing broken, intermittent failures | Both systems program conflicting rules | `kubeProxyMode: "none"` in Kind config |
| 9 | `k8sServiceHost` not set | Pods can't reach kube-apiserver | Cilium doesn't know API server IP | Detect control-plane IP, pass via `--set` |
| 10 | `logger.info()` suppressed | Startup logs invisible, debugging impossible | Python default log level is WARNING | `logging.basicConfig(level=logging.INFO, force=True)` |

---

## Version Compatibility

| Component | Version | Notes |
|-----------|---------|-------|
| Cilium | 1.19.6 | CRD `cilium.io/v2`. Do not use 1.20+ fields without testing |
| Kubernetes | 1.36.1 | Kind cluster |
| Helm | 3.x | Required for `--wait` on CRD resources |
| CoreDNS | 1.14.2 | Patched upstream to 8.8.8.8 + 1.1.1.1 |

When upgrading Cilium: diff the CRD schema, run `helm template` to preview rendered policies, apply to non-production first, confirm all CNPs report `VALID=True`.
