# OpenShell on OpenShift

Deploy OpenShell and run OpenClaw sandboxes on an OpenShift cluster using the provided Makefile.

## Prerequisites

- `oc` CLI authenticated to your OpenShift cluster (with cluster-admin for CRD installation and SCC)
- `helm` v3+
- `openshell` CLI installed locally

## Quick Start

```shell
cd deploy/openshift

# Deploy OpenShell (using the dev version)
make deploy

# Verify everything is running
make status

# Port-forward the gateway (in a separate terminal)
make port-forward

# Create an OpenClaw sandbox
make sandbox-create

# Configure the OpenClaw inside the sandbox
make openclaw-configure SANDBOX=<sandbox-name>

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

This creates the namespace, installs the Sandbox CRD and controller, grants the privileged SCC, installs the Helm chart, and creates an OpenShift Route with edge TLS termination:

```shell
make deploy
```

To pin a specific chart version (e.g., a per-commit pin):

```shell
make deploy HELM_VERSION=0.0.0-dev.<commit-sha>
```

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
make upgrade HELM_VERSION=0.7.0
```

## Teardown

Remove everything (Helm release, route, PVCs):

```shell
make undeploy
```

## Configuration

All variables can be overridden on the command line:

| Variable | Default | Description |
|----------|---------|-------------|
| `NAMESPACE` | `openshell` | OpenShift namespace |
| `HELM_RELEASE` | `openshell` | Helm release name |
| `HELM_CHART` | `oci://ghcr.io/nvidia/openshell/helm-chart` | OCI Helm chart reference |
| `HELM_VERSION` | `0.0.0-dev` | Helm chart version |
| `SANDBOX_IMAGE` | `openclaw` | Sandbox image name for `sandbox-create` |
| `OPENCLAW_PORT` | `18789` | Local port for the OpenClaw dashboard |

Example:

```shell
# Deploy with a specific commit pin
make deploy HELM_VERSION=0.0.0-dev.<commit-sha>

# Deploy a tagged release
make deploy HELM_VERSION=0.6.0

# Deploy to a different namespace
make deploy NAMESPACE=my-ns
```

## Make Targets

Run `make help` to see all available targets:

| Target | Description |
|--------|-------------|
| `deploy` | Full deploy: namespace + CRD + SCC + helm install + route |
| `sandbox-crd` | Install the Sandbox CRD and controller |
| `upgrade` | Helm upgrade with OpenShift overrides |
| `undeploy` | Full teardown: helm uninstall + route + PVCs |
| `route` | Create OpenShift edge-terminated Route |
| `status` | Show pods, routes, services, sandboxes |
| `logs` | Tail gateway logs |
| `port-forward` | Port-forward gateway for local CLI access |
| `sandbox-create` | Create an OpenClaw sandbox |
| `sandbox-list` | List sandboxes |
| `openclaw-start` | Start OpenClaw gateway in a sandbox |
| `openclaw-ui` | Launch OpenClaw dashboard UI |
| `clean` | Delete PVCs and stale resources |
