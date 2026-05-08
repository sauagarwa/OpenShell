# OpenShell on OpenShift

Deploy OpenShell and run OpenClaw sandboxes on an OpenShift cluster using the provided Makefile.

## Prerequisites

- `oc` CLI authenticated to your OpenShift cluster (with cluster-admin for CRD installation and SCC)
- `helm` v3+
- `openshell` CLI installed locally

## Quick Start

```shell
cd deploy/openshift

# Deploy OpenShell (using a specific chart version)
make deploy CHART_VERSION=0.6.0

# Verify everything is running
make status

# Port-forward the gateway (in a separate terminal)
make port-forward

# Create an OpenClaw sandbox
make sandbox-create

# Start the OpenClaw gateway inside the sandbox
make openclaw-start SANDBOX=<sandbox-name>

# Launch the OpenClaw dashboard UI
make openclaw-ui SANDBOX=<sandbox-name>
```

## Chart Versions

The Helm chart is published as an OCI artifact at `oci://ghcr.io/nvidia/openshell/helm-chart`.

| Version | Description |
|---------|-------------|
| `0.6.0`, `0.7.0`, ... | Tagged releases. Tracks matching gateway and supervisor image versions. **Recommended for production.** |
| `0.0.0-dev` | Latest `main` branch. Floating tag updated with each push; uses `:dev` image tag. |
| `0.0.0-dev.<commit-sha>` | Specific `main` commit. Per-commit pinning using full 40-char SHA. |

## Step-by-Step Deployment

### 1. Deploy OpenShell

This creates the namespace, installs the Sandbox CRD and controller, grants the privileged SCC, creates the SSH handshake secret, installs the Helm chart from the OCI registry, and creates an OpenShift Route with edge TLS termination:

```shell
make deploy CHART_VERSION=0.6.0
```

The chart is pulled from `oci://ghcr.io/nvidia/openshell/helm-chart`. OpenShift-specific overrides are applied automatically:

- `pkiInitJob.enabled=false` — skips the PKI init job (not needed on OpenShift)
- `server.disableTls=true` — the OpenShift Route terminates TLS at the edge
- `podSecurityContext.fsGroup=null` — lets OpenShift assign UIDs from the namespace range
- `securityContext.runAsUser=null` — same as above

The Sandbox CRD (`sandboxes.agents.x-k8s.io`) is required for sandbox lifecycle management. It is installed automatically if not already present. CRD installation requires cluster-admin privileges.

### 2. Verify the deployment

```shell
make status
```

This shows pods, services, routes, and sandboxes in the namespace. The gateway pod (`openshell-0`) should be `Running` and `Ready`.

### 3. Check gateway logs

```shell
make logs
```

### 4. Port-forward the gateway

In a separate terminal, start a port-forward to the gateway so the local CLI can reach it:

```shell
make port-forward
```

Keep this running while creating or managing sandboxes.

### 5. Create an OpenClaw sandbox

In your main terminal (with the port-forward running):

```shell
make sandbox-create
```

The output will include the sandbox name (e.g., `showy-dinosaur`). Note it for the next steps.

To use a different sandbox image:

```shell
make sandbox-create SANDBOX_IMAGE=my-image
```

### 6. List sandboxes

```shell
make sandbox-list
```

### 7. Start the OpenClaw gateway in the sandbox

The OpenClaw gateway must be running inside the sandbox before you can access the dashboard:

```shell
make openclaw-start SANDBOX=showy-dinosaur
```

### 8. Launch the OpenClaw dashboard UI

In a separate terminal, run:

```shell
make openclaw-ui SANDBOX=showy-dinosaur
```

This fetches the tokenized dashboard URL from the sandbox, starts a port-forward on `localhost:18789`, and prints the URL to open in your browser.

To use a different local port:

```shell
make openclaw-ui SANDBOX=showy-dinosaur OPENCLAW_PORT=9999
```

## Upgrading

After updating to a newer chart version:

```shell
make upgrade CHART_VERSION=0.7.0
```

## Teardown

Remove everything (Helm release, route, secret, PVCs):

```shell
make undeploy
```

## Building Custom Images

Cross-compile the gateway and supervisor binaries from source and push container images to a registry:

```shell
make images
```

This uses `cargo-zigbuild` for cross-compilation to `linux/amd64` and pushes to the configured image repository.

## Configuration

All variables can be overridden on the command line:

| Variable | Default | Description |
|----------|---------|-------------|
| `NAMESPACE` | `openshell` | OpenShift namespace |
| `HELM_RELEASE` | `openshell` | Helm release name |
| `HELM_CHART` | `oci://ghcr.io/nvidia/openshell/helm-chart` | OCI Helm chart reference |
| `CHART_VERSION` | `0.0.0-dev` | Chart version to install (see Chart Versions above) |
| `SANDBOX_IMAGE` | `openclaw` | Sandbox image name for `sandbox-create` |
| `OPENCLAW_PORT` | `18789` | Local port for the OpenClaw dashboard |
| `IMAGE_REPO` | `ghcr.io/nvidia/openshell` | Container image repository (for custom builds only) |
| `RUST_TARGET` | `x86_64-unknown-linux-gnu` | Rust cross-compilation target |

Example:

```shell
# Deploy a tagged release
make deploy CHART_VERSION=0.6.0

# Deploy the latest dev chart
make deploy CHART_VERSION=0.0.0-dev

# Deploy a specific commit
make deploy CHART_VERSION=0.0.0-dev.8bfd3e1914a684094f472bce6d341706455288d7

# Deploy to a different namespace
make deploy NAMESPACE=my-ns CHART_VERSION=0.6.0
```

## Make Targets

Run `make help` to see all available targets:

| Target | Description |
|--------|-------------|
| `deploy` | Full deploy: namespace + CRD + SCC + secret + helm install + route |
| `sandbox-crd` | Install the Sandbox CRD and controller |
| `upgrade` | Helm upgrade with OpenShift overrides |
| `undeploy` | Full teardown: helm uninstall + route + secret + PVCs |
| `secret` | Create SSH handshake secret |
| `route` | Create OpenShift edge-terminated Route |
| `status` | Show pods, routes, services, sandboxes |
| `logs` | Tail gateway logs |
| `port-forward` | Port-forward gateway for local CLI access |
| `sandbox-create` | Create an OpenClaw sandbox |
| `sandbox-list` | List sandboxes |
| `openclaw-start` | Start OpenClaw gateway in a sandbox |
| `openclaw-ui` | Launch OpenClaw dashboard UI |
| `build` | Cross-compile binaries for linux/amd64 |
| `images` | Build and push gateway + supervisor images |
| `clean` | Delete PVCs and stale resources |
