# AutoSRE Cilium NetworkPolicies

**Zero-trust network isolation for the AutoSRE evaluation platform.**

This Helm chart manages the complete Cilium NetworkPolicy layer for the
AutoSRE system. It does not install Cilium itself — Cilium is provisioned
separately as the cluster CNI (via Kind bootstrap scripts or AKS Azure CNI
Powered by Cilium). This chart applies only the policy resources that enforce
least-privilege connectivity between all platform namespaces.

---

## Why This Chart Exists

The AutoSRE platform has a hard security requirement: **the chaos injection
ports (8081) on Rivulet application pods must never be reachable except from
the isolated `eval` namespace.** If a compromised application pod, a rogue
agent, or an external attacker could trigger `/__chaos/leak-db` or
`/__chaos/cpu-spin`, the entire evaluation harness becomes untrustworthy.

Kubernetes-native `NetworkPolicy` resources cannot express this cleanly
because they lack:

- L7 DNS interception required for FQDN-aware egress control
- The `toEntities: [kube-apiserver]` logical entity
- Cross-namespace endpoint selection via `k8s:io.kubernetes.pod.namespace`
- Host-network entity selection (`fromEntities: [host, remote-node]`) for
  kubelet probes

Cilium's `CiliumNetworkPolicy` CRD provides all four.

---

## The Four Rules That Prevent 90% of Policy Bugs

Read this section before writing or modifying any policy file. Every outage
this chart has produced so far traces to one of these four rules.

### Rule 1 — `k8s:` prefix is mandatory on Kubernetes labels

Cilium stores every Kubernetes label internally with a `k8s:` prefix. The
selector in a `matchLabels` block must use that prefixed form:

```yaml
# WRONG — matches zero endpoints, silently drops the SYN
matchLabels:
  io.kubernetes.pod.namespace: rivulet

# RIGHT
matchLabels:
  k8s:io.kubernetes.pod.namespace: rivulet
```

Application identity labels (`app.kubernetes.io/*`, `app`) work without the
prefix because Cilium special-cases them. `io.kubernetes.pod.namespace` is
**not** special-cased and must always carry the prefix.

The failure mode is a silent drop. Cilium does not return an RST — the SYN
goes into a black hole until the kernel's TCP retry window expires (~2 min).
Init containers that use `nc -z` hang for the full window, and the pod's
state looks like a network problem rather than a policy misconfiguration.

### Rule 2 — Default-deny needs a never-matching rule, not empty arrays

Cilium enables per-direction isolation on an endpoint only when a policy
selects that endpoint **and has at least one rule for that direction**. An
empty `ingress: []` / `egress: []` is accepted by the API server but does
**not** enable isolation.

The portable, universally-accepted idiom is a never-matching rule:

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

The sentinel label `cilium.io/no-such-entity` is a user-namespace label that
no pod carries. Cilium treats the rule as valid and enabled, but it matches
nothing. Result: default-deny with no accidental allow.

**Do not use `ingressDeny` / `egressDeny: fromEntities: [all]`.** Deny rules
are a hard veto that overrides every allow policy in the namespace. They are
for explicit blocklists inside an otherwise permissive setup, not for
establishing a deny baseline. Every allow rule you add afterward will be
silently ignored.

### Rule 3 — Egress alone is not enough; the destination needs ingress

Under default-deny, a flow is permitted only when **both** endpoints agree:

- The source's egress rules must allow the destination.
- The destination's ingress rules must allow the source.

Writing only the source's egress rule produces a flow where the SYN leaves
the source, transits the CNI, and is dropped at the destination's ingress
hook (`bpf_lxc.c:2405`). The source sees a TCP timeout. This looks identical
to a missing egress rule from the source's perspective.

Every cross-service policy must be written as a pair:

```
clients-to-datastores-egress   (clients: "I may talk to postgres/valkey")
postgres-ingress               (postgres: "I accept from clients")
valkey-ingress                 (valkey: "I accept from clients")
```

If you add a new client to an existing egress rule, also check that the
destination's ingress rule already lists it. If you add a new destination
pod, it needs its own ingress policy — default-deny selects it via the
namespace-wide `endpointSelector: {}` and its ingress is closed until you
open it.

### Rule 4 — kubelet probes come from the host, not from a pod

Kubernetes liveness, readiness, and startup probes originate in the node's
network namespace, not from a pod IP. Cilium classifies the source as
`host`. Without an explicit ingress rule for that entity, every probe on
every pod in a default-deny namespace is dropped, and pods alternate between
`Init:0/1` and `CrashLoopBackOff` with no policy-related error message.

Every pod with HTTP probes needs:

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

`remote-node` is included so probes work when the kubelet runs on a
different node from the pod.

---

## Architecture

```
                            ┌───────────────────────────┐
                            │   kube-system (DNS :53)   │
                            │   kube-apiserver :443     │
                            └───────────▲───────────────┘
                                        │ (01: DNS) (06: apiserver)
                                        │
   ┌────────────────────────────────────┼───────────────────────────────┐
   │                                    │                               │
   │  ns/rivulet (System Under Test)    │  ns/sre (Agent)               │
   │                                    │                               │
   │  ┌──────────┐  api-gateway         │  ┌────────────────┐           │
   │  │ frontend │──:8080───►┐          │  │ autosre-agent  │           │
   │  │ :8080    │           │          │  │ :8000          │           │
   │  └──────────┘           ▼          │  └───┬────────────┘           │
   │                  ┌─────────────┐   │      │ (06)                   │
   │                  │ api-gateway │   │      ├──► kube-apiserver :443 │
   │                  │ :8080 :8081 │◄──┼──(05)┤──► postgres    :5432    │
   │                  │ ingestion-  │   │      ├──► valkey      :6379    │
   │                  │   worker    │   │      ├──► openobserve :5080    │
   │                  └──────┬──────┘   │      ├──► otel-gw     :4318    │
   │                         │ (03)     │      └──► world       :443     │
   │                         ▼          │              │                │
   │              ┌──────────────────┐  │              │ (07)           │
   │              │ postgres  :5432  │  │      ┌───────▼─────────┐      │
   │              │ valkey    :6379  │  │      │  openobserve    │      │
   │              └──────────────────┘  │      │  eval harness   │      │
   │                         ▲          │      └─────────────────┘      │
   │                         │ (04)     │                               │
   │                  ┌──────┴──────┐   │                               │
   │                  │ otel-gateway│   │                               │
   │                  │ :4318       │   │                               │
   │                  └─────────────┘   └───────────────────────────────┘
   │
   │  ns/eval (Harness)
   │  ┌──────────────┐
   │  │ fault-runner │──(05)──► rivulet :8081 (chaos)
   │  │ deepeval     │──(05)──► sre      :8000 (agent API)
   │  │              │──(05)──► openobserve :5080
   │  │              │──(05)──► world    :443  (Groq judge)
   │  └──────────────┘
   │
   │  ns/openobserve
   │  ┌──────────────┐
   │  │ openobserve  │◄──(07)── sre-agent, eval harness
   │  │ otel-gateway │◄──(04)── all rivulet pods
   │  └──────────────┘
```

The parenthesized numbers correspond to the policy files in the table below.

---

## Namespace Topology

| Namespace | Workloads | Ports | Role |
|-----------|-----------|-------|------|
| `rivulet` | postgres, valkey, api-gateway, ingestion-worker, frontend | 5432, 6379, 8080, 8081 | System Under Test |
| `sre` | autosre-agent | 8000 | Autonomous remediation |
| `eval` | fault-runner jobs, deepeval harness | ephemeral | Evaluation |
| `openobserve` | openobserve, otel-gateway, otel-daemonset | 5080, 4318, 4317 | Observability |
| `kube-system` | coredns, kube-apiserver | 53, 443 | Cluster control plane |

Default-deny isolation applies to **`rivulet`, `sre`, and `eval`**.
`openobserve` is isolated indirectly by the `openobserve-ingress` policy in
`07-sre-agent-ingress.yaml`, which selects it explicitly. If you add a new
namespace, add it to the default-deny and allow-dns-egress range loops.

---

## Policy Files

Each file has one bounded responsibility. Policies are additive — Cilium
uses an allow-union model where traffic matching any applicable allow rule
is permitted.

The table lists the file name, the CNP resource names inside the file, the
direction of each, and its purpose. **The CNP name is the contract** — the
deploy scripts and this documentation reference CNP names, not file names.
If you rename a file, either keep the CNP names or update every reference.

| File | CNP name(s) | Direction | Purpose |
|------|-------------|-----------|---------|
| `00-default-deny.yaml` | `default-deny` | both | Zero-trust baseline in `rivulet`, `sre`, `eval`. |
| `01-allow-dns-egress.yaml` | `allow-dns-egress` | egress | DNS resolution via `kube-dns` with L7 interception. |
| `02-rivulet-internal.yaml` | `api-gateway-ingress`, `frontend-ingress` | ingress | Frontend → api-gateway :8080; external → frontend :8080; kubelet probes. |
| `03-rivulet-to-datastores.yaml` | `clients-to-datastores-egress`, `postgres-ingress`, `valkey-ingress` | egress + ingress | api-gateway and ingestion-worker → postgres :5432 and valkey :6379. Both sides of the flow. |
| `04-rivulet-to-otel.yaml` | `rivulet-to-otel` | egress | All pods in `rivulet` → otel-gateway :4318. |
| `05-eval-to-chaos-ports.yaml` | `eval-egress` | egress | eval → rivulet :8081 (chaos), sre :8000, openobserve :5080, world :443. |
| `06-sre-agent-egress.yaml` | `sre-agent-egress` | egress | Agent → kube-apiserver :443, postgres :5432, valkey :6379, openobserve :5080, otel-gw :4318, world :443. |
| `07-sre-agent-ingress.yaml` | `openobserve-ingress`, `sre-agent-ingress` | ingress | openobserve ← sre-agent, eval; agent ← openobserve webhooks, eval. |
| `08-ingestion-worker-ingress.yaml` | `ingestion-worker-ingress` | ingress | Kubelet probes on :8080, eval chaos on :8081. |

Every file is guarded by `{{- if .Values.networkPolicies.enabled }}` at the
top and `{{- end }}` at the bottom. Files with multiple CNPs use a single
guard block that wraps the whole file — do not interleave `---` separators
with guard markers.

---

## Security Invariants

These are the non-negotiable guarantees this chart enforces. If any
invariant is violated, the evaluation harness is compromised.

1. **Chaos port isolation.** TCP/8081 on Rivulet pods is reachable only from
   pods in `eval`. No pod in `rivulet`, `sre`, `openobserve`, or
   `kube-system` can reach it. No external traffic can reach it.

2. **Agent cannot self-inject faults.** The `sre` namespace has no egress
   rule permitting TCP/8081 to Rivulet pods. The agent can observe and
   remediate, but never trigger chaos.

3. **Datastore access is role-scoped.** Only `api-gateway` and
   `ingestion-worker` pods can reach postgres and valkey. `frontend` cannot
   bypass the API layer to access datastores directly.

4. **Agent egress is explicitly enumerated.** The agent can reach exactly
   six destinations: kube-apiserver, postgres, valkey, openobserve,
   otel-gateway, and world:443. All other egress is denied by the
   default-deny baseline.

5. **DNS is intercepted, not just allowed.** The `allow-dns-egress` policy
   uses `rules.dns` with `matchPattern: "*"`, enabling Cilium's DNS proxy to
   observe and cache resolutions. This is required for any future
   `toFQDNs` policies and provides DNS-level audit visibility.

6. **Every destination has an explicit ingress rule.** Under default-deny,
   the CNP's isolation model requires the destination to also carry an
   allow rule. There is no implicit trust between namespaces.

7. **Kubelet probes are allowed only from the host entity.** No pod in any
   namespace can spoof a probe source. The `fromEntities: [host, remote-node]`
   selector is Cilium's identity for the node's network namespace, which is
   not spoofable from a pod.

---

## Prerequisites

- Cilium installed as the cluster CNI with policy enforcement enabled
- `helm` 3.x
- `kubectl` with cluster-admin context
- All target namespaces created (`rivulet`, `sre`, `eval`, `openobserve`)
- Application pods labeled with `app.kubernetes.io/name`

### Required Pod Labels

Policies select endpoints by these labels. Deploy scripts must set them on
every pod template.

```yaml
labels:
  app.kubernetes.io/name: api-gateway        # also: ingestion-worker, frontend,
                                             #       postgres, valkey, autosre-agent,
                                             #       otel-gateway, openobserve
  app.kubernetes.io/part-of: rivulet         # rivulet namespace pods only
```

StatefulSets whose pods do not carry `app.kubernetes.io/name` (valkey in
this platform uses `app: valkey`) are matched by their own labels. Verify
with `kubectl get pod <name> --show-labels` before writing a selector.

---

## Deployment

```bash
helm upgrade --install autosre-cilium infra/k8s/cilium/ \
  --namespace kube-system \
  --wait \
  --timeout 120s

# All policies must report VALID=True
kubectl get ciliumnetworkpolicy -A

# Confirm Cilium has compiled the policy set
kubectl exec -n kube-system ds/cilium -- cilium policy get
```

If `helm upgrade` fails because the chart already has CRDs installed
manually, `kubectl apply -f` each file individually. The chart is a thin
wrapper — every file is a standalone YAML.

### Uninstall

```bash
helm uninstall autosre-cilium --namespace kube-system
```

Removing the chart removes all `CiliumNetworkPolicy` resources. Endpoints
revert to unrestricted policy mode (Cilium's default when no policy selects
them). Reinstalling is safe and idempotent.

---

## Verification

### Confirm all policies are valid

```bash
kubectl get cnp -A -o custom-columns=\
'NAMESPACE:.metadata.namespace,NAME:.metadata.name,VALID:.status.conditions[?(@.type=="Valid")].status'

# Every row must be VALID=True.
# VALID=False means the Cilium agent rejected the policy schema.
# A rejected policy is NOT enforced — traffic is unrestricted for that selector.
```

### Confirm isolation actually took effect

```bash
# Every pod in a default-deny namespace should have a CiliumEndpoint.
kubectl get cep -n rivulet
kubectl get cep -n sre

# A missing CEP means Cilium is not managing the pod (host network,
# or the pod is not in the namespace Cilium is watching).
```

### Manual chaos port isolation test

```bash
RIV_POD_IP=$(kubectl get pod -n rivulet -l app.kubernetes.io/name=api-gateway \
  -o jsonpath='{.items[0].status.podIP}')

# From eval — SUCCEEDS (200)
kubectl run chaos-ok -n eval --rm -it --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  "http://${RIV_POD_IP}:8081/__chaos/reset"

# From rivulet — TIMES OUT
kubectl run chaos-bad-1 -n rivulet --rm -it --image=curlimages/curl -- \
  curl -s --connect-timeout 5 -X POST \
  "http://${RIV_POD_IP}:8081/__chaos/reset"

# From sre — TIMES OUT
kubectl run chaos-bad-2 -n sre --rm -it --image=curlimages/curl -- \
  curl -s --connect-timeout 5 -X POST \
  "http://${RIV_POD_IP}:8081/__chaos/reset"
```

A timeout is the correct outcome. A "connection refused" (RST) means the
packet reached the destination and was rejected at the socket layer —
which means it passed Cilium, which means the policy is wrong.

### Cross-namespace flow test

```bash
# frontend → api-gateway :8080 — SUCCEEDS
kubectl exec -n rivulet deploy/frontend -- \
  wget -qO- http://api-gateway.rivulet.svc.cluster.local:8080/healthz

# frontend → postgres :5432 — TIMES OUT (frontend has no egress to postgres)
kubectl exec -n rivulet deploy/frontend -- \
  nc -zv -w3 postgres.rivulet.svc.cluster.local 5432
```

---

## Adding a New Service

Use this checklist when introducing a new workload. Every step is required;
skipping any one produces a silent failure that is difficult to diagnose.

1. **Label the pod template correctly.**

   ```yaml
   metadata:
     labels:
       app.kubernetes.io/name: <service-name>
       app.kubernetes.io/part-of: rivulet   # if in rivulet namespace
   ```

2. **Decide whether the pod should be isolated.** Under default-deny,
   isolation is enabled by the namespace-wide `endpointSelector: {}` in
   `00-default-deny.yaml`. Nothing extra is needed — the pod is
   automatically isolated the moment it starts.

3. **Write an ingress CNP for the pod** if anything needs to reach it.

   - kubelet probes: `fromEntities: [host, remote-node]` on the probe port
   - Other in-cluster services: `fromEndpoints` with prefixed namespace label
   - External traffic: `fromEntities: [world]` on the exposed port

4. **Add the pod's egress needs** to the appropriate egress CNP. If the pod
   needs to reach postgres, add it to the `clients-to-datastores-egress`
   `endpointSelector` and ensure `postgres-ingress` lists the new source.

5. **If the pod exposes a chaos port**, add the eval namespace as an
   ingress source on that port in the pod's ingress CNP and confirm
   `05-eval-to-chaos-ports.yaml` already covers the port for the eval side.

6. **Update the deploy script's preflight** to include the new CNP name in
   `REQUIRED_CNPS`.

7. **Add the file to this README's policy table.**

8. **Verify with `kubectl get cnp -A`** that the new policy is `VALID=True`
   and with `kubectl get cep -n <ns>` that the pod has a CiliumEndpoint.

---

## Adding a New Flow

A flow is a new permission for one workload to talk to another. Both sides
must be updated.

1. **Identify source and destination.** Get the exact labels:

   ```bash
   kubectl get pod <dest-pod> --show-labels
   ```

2. **Add the source to the destination's ingress CNP.** If the destination
   has no ingress CNP yet, create one. Match the destination's endpoint
   selector exactly, and use `k8s:io.kubernetes.pod.namespace` on the source
   matchLabel.

3. **Add the destination to the source's egress CNP.** If the source has no
   egress CNP, create one.

4. **Add both to the same PR.** A PR that adds only one side will appear to
   work locally (the SYN leaves the source) but fail in the cluster with a
   TCP timeout at the destination.

5. **Test with the drop monitor running:**

   ```bash
   CILIUM_POD=$(kubectl -n kube-system get pods -l k8s-app=cilium \
     --field-selector spec.nodeName=$(kubectl get pod <source> -o jsonpath='{.spec.nodeName}') \
     -o jsonpath='{.items[0].metadata.name}')

   kubectl -n kube-system exec "$CILIUM_POD" -c cilium-agent -- \
     cilium-dbg monitor --type drop &
   MON_PID=$!

   # Trigger the flow
   kubectl exec <source> -- <test-command>

   kill $MON_PID
   ```

   Zero `Policy denied` lines = both sides correct. Any drop line names the
   source identity, destination identity, and destination port — that tells
   you exactly which policy is missing.

---

## Troubleshooting

### A flow times out but I see no drops

The drop is happening at the destination's ingress hook, which the source's
node may not log. Run the monitor on the destination's node:

```bash
DEST_NODE=$(kubectl get pod <dest> -o jsonpath='{.spec.nodeName}')
CILIUM_POD=$(kubectl -n kube-system get pods -l k8s-app=cilium \
  --field-selector spec.nodeName="$DEST_NODE" -o jsonpath='{.items[0].metadata.name}')

kubectl -n kube-system exec "$CILIUM_POD" -c cilium-agent -- \
  cilium-dbg monitor --type drop
```

Drop lines are labeled with the file and line number in Cilium's eBPF source.
`bpf_lxc.c:2405` is the destination's ingress hook — that means the source
sent the packet but the destination's ingress policy blocked it.

### A flow succeeds when it should not

Check for a policy that selects the destination but has an overly broad rule:

```bash
kubectl get cnp -n <ns> -o json | jq -r '
  .items[] | select(.spec.endpointSelector == {}) |
  "\(.metadata.name): endpointSelector matches every pod"'
```

An `endpointSelector: {}` with rules creates a namespace-wide allow. The
`rivulet-to-otel` policy uses this intentionally (every pod needs telemetry
egress). Any other use of an empty selector should be reviewed.

### A policy reports `VALID=False`

```bash
kubectl -n <ns> describe cnp <name> | tail -30
```

Common causes:

- A field from Cilium 1.21-dev docs used against a 1.20 or 1.19 cluster
- `port` written as an integer instead of a string (`port: 8080` → invalid,
  `port: "8080"` → valid)
- Empty `ingress: []` / `egress: []` in a Cilium version that requires at
  least one rule to enable isolation

Fix and reapply. A `VALID=False` policy is **not enforced** — the namespace
may appear to have default-deny when it does not.

### DNS resolution fails after applying policies

1. Confirm the kube-dns label selector matches the cluster's DNS pods:

   ```bash
   kubectl get pods -n kube-system -l k8s-app=kube-dns --show-labels
   ```

2. Confirm the DNS egress policy uses `protocol: ANY` for port 53, not
   `UDP` or `TCP` alone. DNS uses both.

3. Confirm the DNS egress policy uses the `k8s:` prefix:

   ```bash
   kubectl get cnp -n rivulet allow-dns-egress -o jsonpath='{.spec.egress[0].toEndpoints[0].matchLabels}'
   # Must include: "k8s:io.kubernetes.pod.namespace": "kube-system"
   ```

### Pods alternate between Init and CrashLoopBackOff

Almost always the kubelet probe rule is missing from the pod's ingress CNP.
See Rule 4.

### `enableServiceLinks` injects unexpected env vars

Kubelet injects `<SVCNAME>_PORT=tcp://<clusterIP>:<port>` for every Service
in the namespace, unless the pod spec sets `enableServiceLinks: false`.
Applications that read `${VALKEY_PORT}` will get the tcp:// URL instead of
the integer port.

This is a Kubernetes behavior, not a Cilium one, but the two interact: when
a policy misconfiguration causes a pod to restart, the newly-started pod
reads the injected env vars and fails differently than the first attempt,
producing confusing diagnostics. Set `enableServiceLinks: false` on every
pod template in a namespace that has Services with names that match
application config keys.

---

## Bugs Already Hit — Read Before Modifying

These are real outages this chart produced. Each one had a silent failure
mode and cost significant debugging time. Do not reintroduce them.

### 1. `io.kubernetes.pod.namespace` without the `k8s:` prefix

**Symptom.** Init container hangs at "waiting for postgres ..." for the
kernel's full TCP retry window. No drops appear in `cilium-dbg monitor` on
the source's node.

**Root cause.** The postgres matchLabel was written without the prefix.
Cilium resolved the selector to zero endpoints and installed an empty
`toEndpoints` rule. Every SYN was dropped at the destination's ingress hook.

**Fix.** Apply Rule 1 unconditionally.

**Detection.** Add a CI check that greps every matchLabels block for
`io.kubernetes.pod.namespace` and fails if any occurrence lacks the `k8s:`
prefix.

### 2. `ingressDeny: fromEntities: [all]` used as default-deny

**Symptom.** Every allow policy in the namespace is silently ignored. Even
correct egress and ingress rules produce drops.

**Root cause.** Deny rules are a hard veto in Cilium's policy model.
`ingressDeny: fromEntities: [all]` overrides every allow rule that matches
the same flow. There is no precedence order — deny always wins.

**Fix.** Replace with the never-matching-rule idiom (Rule 2).

### 3. Egress-only policies

**Symptom.** Source pod can send packets, but every flow times out. Drop
monitor on the source node shows nothing. Drop monitor on the destination
node shows `Policy denied` at `bpf_lxc.c:2405`.

**Root cause.** The egress rule was written. The destination's ingress rule
was not. Under default-deny, both are required.

**Fix.** Apply Rule 3. Every cross-service flow is a pair of policies.

### 4. Missing kubelet probe ingress rule

**Symptom.** Pod reaches `Running`, nginx or the app starts, readiness probe
never passes, liveness kills and restarts after ~30s. `0/1 READY` forever.

**Root cause.** No ingress rule for `fromEntities: [host, remote-node]`.
Kubelet probes originate in the node's network namespace, not from a pod.

**Fix.** Apply Rule 4 to every pod with HTTP probes.

**Detection.** `kubectl get pod <name>` shows `Liveness probe failed` and
`Readiness probe failed` events. `cilium-dbg monitor --type drop` on the
pod's node shows drops with the source identity equal to the host's
reserved identity.

### 5. Empty `ingress: []` / `egress: []` in a default-deny policy

**Symptom.** The CNP reports `VALID=True`. Policies are applied. Nothing is
actually isolated.

**Root cause.** Empty arrays do not enable isolation. This is easy to
mistake for a no-op default-deny that "works because nothing matches."

**Fix.** Never use empty arrays. Use a never-matching rule.

### 6. Reusing an old image tag after rebuild

**Symptom.** A rebuilt image is pushed to the same tag but the pod keeps
running the old code. Logs show old behavior. `kubectl get pod -o yaml`
confirms the pod spec has the right image tag.

**Root cause.** `imagePullPolicy: IfNotPresent` with a mutable tag. Kubelet
sees the tag as cached and does not re-pull. `:latest` is not special — the
policy explicitly overrides Kubernetes' default `Always` for `:latest`.

**Fix.** For mutable tags use `imagePullPolicy: Always`. For immutable
deployments use a content-addressed tag (`sha-<short-sha>`) with
`IfNotPresent`. The deploy scripts choose the right policy based on the tag
name automatically.

---

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| CiliumNetworkPolicy over NetworkPolicy | Cross-namespace selection, L7 DNS interception, `toEntities: [kube-apiserver]`, host entity selection, and per-direction isolation are not available in the Kubernetes-native API. |
| Never-matching rule for default-deny | Empty arrays do not enable isolation in all Cilium versions. The sentinel label `cilium.io/no-such-entity` is portable across the 1.18–1.21 CRD lineage. |
| `toEntities: [kube-apiserver]` over CIDR | The API server address varies across environments (Kind uses a container IP, AKS uses an FQDN). The logical entity is environment-independent. |
| `toEntities: [world]` for Groq | The Groq API resolves to dynamic IPs behind a CDN. CIDR-based rules break on IP rotation. `world` covers all external traffic on the specified port. |
| Ports as strings | The Cilium 1.20.x CRD defines `PortProtocol.port` as a string to support named ports. Numeric YAML values fail validation. |
| `protocol: ANY` for DNS port 53 | DNS uses UDP and TCP. Restricting to one breaks resolution under conditions that are hard to reproduce. |
| No L7 HTTP rules on internal traffic | L7 rules activate the Envoy proxy, adding latency and a failure point. For service-to-service traffic, L3/L4 identity-based policy is sufficient. |
| Separate files per concern | Each file has one bounded responsibility. `git blame` is meaningful, individual files can be applied during debugging, and a YAML error in one file does not break unrelated flows. |
| No `ingressDeny` / `egressDeny` | The allow-union model with default-deny is simpler to reason about. Deny rules add precedence complexity that has produced bugs every time they were used. |
| StatefulSet pods matched by their own labels | Valkey uses `app: valkey`, not `app.kubernetes.io/name`. Forcing a relabel would require modifying the StatefulSet's pod template; matching the actual labels is simpler and correct. |
| Kubernetes labels always written with `k8s:` prefix | Prevents the most common silent-drop bug. Enforced by CI. |

---

## Version Compatibility

| Component | Version in use | Notes |
|-----------|---------------|-------|
| Cilium | 1.19.6 (kind cluster) | CRD `cilium.io/v2`. Do not use fields from 1.20+ docs without testing. |
| Kubernetes | 1.32+ | Required for `discovery.k8s.io/v1` EndpointSlice. |
| Helm | 3.12+ | Required for `--wait` on CRD-backed resources. |

When upgrading Cilium:

1. Diff the CRD between the current and target versions on GitHub.
2. Run `helm template` against the current file set and diff against the
   cluster's rendered policies.
3. Apply to a non-production cluster first and run the verification suite
   above.
4. Confirm every CNP reports `VALID=True` after upgrade.

The version noted here must match what is actually running. An earlier
revision of this document claimed 1.20.2; the running cluster was 1.19.6.
The mismatch caused repeated confusion during debugging because the
documented CRD schema did not match the enforced one.

---

## References

- [Cilium Network Policy](https://docs.cilium.io/en/stable/network/kubernetes/policy/)
- [Cilium Layer 3 Policies](https://docs.cilium.io/en/stable/security/policy/layer3/)
- [Cilium Layer 4 Policies](https://docs.cilium.io/en/stable/security/policy/layer4/)
- [Cilium Layer 7 Policies](https://docs.cilium.io/en/stable/security/policy/layer7/)
- [Cilium Kubernetes Constructs in Policy](https://docs.cilium.io/en/stable/security/policy/kubernetes/)
- [Cilium Policy Enforcement Modes](https://docs.cilium.io/en/stable/security/policy/intro/)
```

---

## What changed vs. the original README

| Section | Change | Why |
|---|---|---|
| **The Four Rules** | New top-level section | Encodes the four invariants that caused every outage. Read first, before modifying anything. |
| **Architecture diagram** | Redrawn with explicit port numbers and directional arrows per flow | Original was a mix of topology and intent; new one maps 1:1 to the policy files. |
| **Policy files table** | Now lists **file name AND CNP name** with direction per rule | Original conflated the two; the deploy script checks by CNP name and would silently pass when they diverged. |
| **`enableDefaultDeny` references** | Removed | Not a CNP field. Original claimed it existed; the correct idiom is the never-matching rule. |
| **`ingressDeny` / `egressDeny` guidance** | Explicitly warns against it | Every use in this project has broken something. |
| **Default-deny pattern** | Documented as never-matching rule, not empty arrays | Empty arrays do not isolate. Every CNP in the chart now uses the sentinel label. |
| **k8s: prefix** | Promoted to Rule 1 | The single most common cause of silent drops. |
| **Adding a New Service** | New checklist | Guides future agents/services through the required steps in order. |
| **Adding a New Flow** | New checklist | Enforces the "both sides" pattern that prevents egress-only bugs. |
| **Bugs Already Hit** | New section | Postmortem catalog of the six outages this chart caused, with symptom/root cause/fix/detection. |
| **Version Compatibility** | Corrected to 1.19.6 (actual) | Original claimed 1.20.2, which caused confusion because CRD schemas differ. |
| **kubelet probe rules** | Promoted to Rule 4 | Second-most-common cause of pod failures. |
| **Troubleshooting** | Expanded | Added drop-monitor-on-destination guidance, `VALID=False` diagnosis, `enableServiceLinks` interaction. |
| **`08-ingestion-worker-ingress.yaml`** | Added to table | The ingestion-worker needs its own ingress policy for kubelet probes and eval chaos calls. |
| **CI detection hints** | Added throughout | Suggests a grep-based pre-commit check for the `k8s:` prefix. |
