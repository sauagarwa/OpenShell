# Deploying OpenShell on Red Hat OpenShift

This guide covers deploying OpenShell on a Red Hat OpenShift cluster,
including the gateway, sandbox pods, policy engine, and privacy router.

## Prerequisites

- OpenShift 4.x cluster with `oc` CLI authenticated
- Helm 3.x
- Cluster-admin access (for SCC and CRD creation)

## Architecture Differences from k3s

On the embedded k3s cluster, the supervisor binary (`openshell-sandbox`) is
pre-loaded onto every node at `/opt/openshell/bin/` and mounted into sandbox
pods via a `hostPath` volume.  OpenShift's SELinux policy (RHCOS) blocks
execution of `hostPath` binaries labeled `var_t` — even with `spc_t` container
context, the `entrypoint` transition is denied.

To work around this, the OpenShift deployment uses a **DaemonSet** that:

1. Copies the supervisor binary from `ghcr.io/nvidia/openshell/cluster:latest`
   to each labeled node's `/opt/openshell/bin/` via a `hostPath` volume.
2. Relabels the binary to `container_file_t` using `nsenter` to enter the
   host's mount namespace, which ensures the SELinux label persists on the
   actual host filesystem (not just the container's bind mount view).

No custom images are required — the deployment uses the default upstream
images from `ghcr.io`.

> **Note:** All commands below assume you are at the OpenShell repository
> root and your Helm release is named `openshell`. If you use a different
> release name, SCC and ClusterRoleBinding names will differ — run
> `oc get scc` and `oc get clusterrolebinding` to find the rendered names.

## Step 1: Deploy the Agent Sandbox Controller CRD

The `Sandbox` CRD and controller must be installed cluster-wide before
deploying the Helm chart.

```bash
oc apply -f deploy/kube/manifests/agent-sandbox.yaml
```

Verify the controller is running:

```bash
oc get pods -n agent-sandbox-system
```

## Step 2: Create the Namespace and Secrets

```bash
oc new-project openshell 2>/dev/null || oc project openshell

# Create the SSH handshake secret
oc create secret generic openshell-ssh-handshake \
  --from-literal=secret=$(openssl rand -hex 32) \
  -n openshell
```

## Step 3: Deploy the Helm Chart

```bash
helm install openshell ./deploy/helm/openshell \
  -n openshell \
  -f ./deploy/helm/openshell/values-openshift.yaml
```

The `values-openshift.yaml` overlay configures:

| Setting | Value | Purpose |
|---------|-------|---------|
| `service.type` | `ClusterIP` | OpenShift Route handles external traffic |
| `podSecurityContext.fsGroup` | `null` | Let OpenShift assign from namespace range |
| `securityContext.runAsUser` | `null` | Let OpenShift assign from namespace range |
| `server.disableTls` | `true` | Gateway listens on plaintext HTTP |
| `server.disableGatewayAuth` | `true` | No mTLS client certs required |
| `openshift.enabled` | `true` | Enables Route and SCC templates |
| `openshift.scc.create` | `true` | Creates custom SCC for sandbox pods |

## Step 4: Patch RBAC for the Sandbox Controller

The `agent-sandbox-controller` needs additional permissions to manage
sandbox resources with owner references:

```bash
# Allow the controller to update sandbox finalizers
oc patch clusterrole agent-sandbox-controller --type=json -p '[
  {"op":"add","path":"/rules/-","value":{
    "apiGroups":["agents.x-k8s.io"],
    "resources":["sandboxes/finalizers"],
    "verbs":["update","patch"]
  }}
]'

# Grant admin in the openshell namespace for owner reference management
oc apply -n openshell -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: agent-sandbox-finalizer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admin
subjects:
  - kind: ServiceAccount
    name: agent-sandbox-controller
    namespace: agent-sandbox-system
EOF
```

## Step 5: Label Nodes and Deploy the Supervisor Loader

Sandbox pods run on nodes labeled with `openshell.io/sandbox=true`.  The
DaemonSet only targets labeled nodes, so you control exactly which nodes
host sandboxes.

```bash
# Label one (or more) nodes for sandbox workloads
NODE_NAME=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
oc label node "$NODE_NAME" openshell.io/sandbox=true
```

### Create the Supervisor Loader ServiceAccount and RBAC

The DaemonSet needs the `privileged` SCC to copy the binary and relabel
it with `nsenter`:

```bash
oc create sa openshell-supervisor-loader -n openshell

oc apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: openshell-supervisor-loader-privileged
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:privileged
subjects:
  - kind: ServiceAccount
    name: openshell-supervisor-loader
    namespace: openshell
EOF
```

### Deploy the Supervisor Loader DaemonSet

This DaemonSet uses two init containers:

1. **copy-supervisor** — copies the supervisor binary from the cluster
   image to the node's `/opt/openshell/bin/` via hostPath.
2. **relabel-selinux** — uses `nsenter -t 1 -m` (entering PID 1's mount
   namespace via `hostPID: true`) to run `chcon` on the host filesystem,
   setting the SELinux label to `container_file_t` so sandbox pods can
   execute it.

```bash
oc apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: openshell-supervisor-loader
  namespace: openshell
  labels:
    app.kubernetes.io/name: openshell-supervisor-loader
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: openshell-supervisor-loader
  template:
    metadata:
      labels:
        app.kubernetes.io/name: openshell-supervisor-loader
    spec:
      hostPID: true
      serviceAccountName: openshell-supervisor-loader
      nodeSelector:
        openshell.io/sandbox: "true"
      initContainers:
      - name: copy-supervisor
        image: ghcr.io/nvidia/openshell/cluster:latest
        command:
        - sh
        - -c
        - |
          mkdir -p /host-bin
          cp /opt/openshell/bin/openshell-sandbox /host-bin/openshell-sandbox
          chmod 755 /host-bin/openshell-sandbox
        securityContext:
          privileged: true
          runAsUser: 0
        volumeMounts:
        - name: host-bin
          mountPath: /host-bin
      - name: relabel-selinux
        image: registry.access.redhat.com/ubi9/ubi:latest
        command:
        - sh
        - -c
        - |
          nsenter -t 1 -m -- chcon -t container_file_t /opt/openshell/bin/openshell-sandbox
        securityContext:
          privileged: true
          runAsUser: 0
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.10
        resources:
          requests:
            cpu: 1m
            memory: 4Mi
      volumes:
      - name: host-bin
        hostPath:
          path: /opt/openshell/bin
          type: DirectoryOrCreate
EOF
```

Verify the DaemonSet is running (init containers completed, main pod running):

```bash
oc get pods -n openshell -l app.kubernetes.io/name=openshell-supervisor-loader
```

Verify the SELinux label was set correctly:

```bash
oc logs -n openshell -l app.kubernetes.io/name=openshell-supervisor-loader \
  -c relabel-selinux
```

## Step 6: Verify the Deployment

```bash
# Gateway should be 1/1 Running
oc get pods -n openshell

# Check gateway logs
oc logs openshell-0 -n openshell

# Verify the SCC was created
oc get scc openshell-sandbox
```

## Step 7: Connect and Create a Sandbox

```bash
# Port-forward to the gateway
oc port-forward statefulset/openshell 9090:8080 -n openshell &

# Set the gateway endpoint
export OPENSHELL_GATEWAY_ENDPOINT=http://localhost:9090

# Create a sandbox
./target/debug/openshell sandbox create --name my-sandbox --no-bootstrap
```

## Network Policies and Sandbox Policy Enforcement

The Helm chart deploys an **ingress** NetworkPolicy for sandbox pods:

- Only the gateway pod can reach sandbox SSH (port 2222), blocking
  lateral movement from other in-cluster workloads.

**Egress is not restricted at the Kubernetes NetworkPolicy level.**
Instead, the sandbox supervisor proxy acts as the policy gateway:

1. All outbound connections from SSH sessions are intercepted by the
   supervisor's HTTP CONNECT proxy.
2. The proxy evaluates each connection against the sandbox's OPA policy.
3. Without an explicit policy, connections are **denied by default**
   (the proxy returns HTTP 403).

```
sandbox@my-sandbox:~$ curl -sS https://api.github.com/zen
curl: (56) CONNECT tunnel failed, response 403
```

To allow specific outbound access, set a sandbox policy:

```bash
openshell policy set <sandbox-name> \
  --policy examples/sandbox-policy-quickstart/policy.yaml --wait
```

After the policy is loaded, allowed connections succeed:

```
sandbox@my-sandbox:~$ curl -sS https://api.github.com/zen
Encourage flow.
```

> **Why no egress NetworkPolicy?** A Kubernetes egress NetworkPolicy
> would block connections at the network level *before* the supervisor
> proxy can forward them — even for destinations the policy explicitly
> allows. The supervisor proxy is the correct enforcement point because
> it can make dynamic, per-request policy decisions via OPA.

## Dashboard UI (Optional)

A lightweight web UI for listing, creating, and deleting sandboxes is
included in `deploy/openshift-ui/`.

### Build and push the image

```bash
# From the OpenShell repo root
cd deploy/openshift-ui
podman build --platform linux/amd64 \
  -t <your-registry>/openshell-dashboard:latest .
podman push <your-registry>/openshell-dashboard:latest
```

### Deploy on OpenShift

Edit `deploy/openshift-ui/k8s.yaml` and replace the `image:` with your
registry path, then apply:

```bash
oc apply -f deploy/openshift-ui/k8s.yaml -n openshell
```

The dashboard communicates with the gateway over in-cluster gRPC
(`openshell.openshell.svc.cluster.local:8080`). An OpenShift Route with
edge TLS termination is created automatically.

> **Note:** If you used a different Helm release name or namespace, update
> the `OPENSHELL_GATEWAY` environment variable in `k8s.yaml` accordingly.

## Troubleshooting

### Gateway pod stuck in `ContainerCreating` with TLS secret errors

```
MountVolume.SetUp failed for volume "tls-cert": secret "openshell-server-tls" not found
```

Ensure `server.disableTls: true` is set in your values file and the
gateway pod has been restarted after the Helm upgrade:

```bash
oc delete pod openshell-0 -n openshell
```

### Sandbox pod: `Permission denied` or exit code 139

SELinux on RHCOS blocks execution of `hostPath` binaries labeled `var_t`.
Verify the supervisor binary has been relabeled to `container_file_t`:

```bash
# Check the DaemonSet relabel init container log
oc logs -n openshell -l app.kubernetes.io/name=openshell-supervisor-loader \
  -c relabel-selinux
```

If the label is wrong, delete the DaemonSet pod to trigger re-execution
of the init containers:

```bash
oc delete pods -n openshell -l app.kubernetes.io/name=openshell-supervisor-loader
```

**Key**: the DaemonSet must use `hostPID: true` and `nsenter -t 1 -m --`
to relabel in the host's mount namespace.  Plain `chcon` through a bind
mount does NOT persist on RHCOS.

### Sandbox pod: `cannot set blockOwnerDeletion`

The `agent-sandbox-controller` lacks finalizer permissions.  Apply the
RBAC patches from Step 4.

### Sandbox pod: `not usable by user or serviceaccount`

The custom SCC is not bound to the correct service accounts.  The Helm
chart's `openshift-scc.yaml` binds it to the gateway SA,
`agent-sandbox-controller`, and the `default` SA in the openshell
namespace.  Verify:

```bash
oc get clusterrolebinding openshell-sandbox-scc -o yaml
```

### CLI: `failed to read TLS CA`

The CLI is trying to load TLS certificates for an `http://` endpoint.
This requires the CLI code change in `crates/openshell-cli/src/tls.rs`
that skips TLS material loading for plaintext endpoints.

## OpenShift-Specific Helm Templates

The chart includes these OpenShift-specific templates:

- **`openshift-route.yaml`** — Creates an OpenShift Route for external
  gateway access.  When the gateway runs with `disableTls: true` (the
  default OpenShift overlay), use **`edge`** termination so the router
  terminates TLS and forwards plaintext to the gateway.  Use `passthrough`
  only when the gateway itself handles TLS.

- **`openshift-scc.yaml`** — Creates a custom `SecurityContextConstraints`
  for sandbox pods with capabilities `SYS_ADMIN`, `NET_ADMIN`,
  `SYS_PTRACE`, `SYSLOG`, `runAsUser: RunAsAny`, `spc_t` SELinux context,
  and `hostPath` volume support.  Also creates the `ClusterRole` and
  `ClusterRoleBinding` granting the SCC to the relevant service accounts.

## Files Modified/Created for OpenShift Support

| File | Description |
|------|-------------|
| `deploy/helm/openshell/values-openshift.yaml` | OpenShift values overlay |
| `deploy/helm/openshell/templates/openshift-route.yaml` | Route template |
| `deploy/helm/openshell/templates/openshift-scc.yaml` | SCC + RBAC template |
| `crates/openshell-cli/src/tls.rs` | CLI fix for plaintext HTTP endpoints |
| `deploy/helm/openshell/values.yaml` | Added `seccompProfile` and `openshift` config |
| `deploy/helm/openshell/templates/networkpolicy.yaml` | Ingress NetworkPolicy for sandbox pods (egress intentionally omitted — see Network Policies section) |
| `deploy/docker/Dockerfile.supervisor` | Minimal supervisor image (for alternative init-container approach) |
| `deploy/openshift-ui/` | Dashboard web UI (Flask + gRPC) for managing sandboxes |
| `examples/sandbox-security-test/` | Security enforcement test (filesystem + network policy) |
