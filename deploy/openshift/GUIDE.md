# OpenShell on OpenShift -- Step-by-Step Guide

This guide walks through deploying OpenShell on OpenShift and running an OpenClaw sandbox using `oc`, `helm`, and `openshell` CLI commands.

## Prerequisites

- `oc` CLI authenticated to your OpenShift cluster (cluster-admin required for CRD and SCC steps)
- `helm` v3+
- `openshell` CLI installed locally

## 1. Create the namespace

```shell
oc new-project openshell
```

## 2. Install the Sandbox CRD

Check if the Sandbox CRD is already installed:

```shell
oc get crd sandboxes.agents.x-k8s.io
```

If not found, install it:

```shell
oc apply -f deploy/kube/manifests/agent-sandbox.yaml
```

Verify the CRD and controller are running:

```shell
oc get crd sandboxes.agents.x-k8s.io
oc get pods -n agent-sandbox-system
```

You should see `agent-sandbox-controller-0` in `Running` state.

## 3. Fix OpenShift Security Context Constraints (SCC)

OpenShift's default `restricted-v2` SCC blocks sandbox pods that require elevated privileges (`runAsUser: 0`, `NET_ADMIN`, `SYS_ADMIN`, etc.). Grant the `privileged` SCC to the required service accounts:

```shell
# Allow the sandbox controller to create privileged pods
oc adm policy add-scc-to-user privileged -z agent-sandbox-controller -n agent-sandbox-system

# Allow sandbox pods in the openshell namespace to run privileged
oc adm policy add-scc-to-user privileged -z default -n openshell
```

The sandbox controller also needs RBAC permission to set finalizers on Sandbox resources (required for `blockOwnerDeletion` on child PVCs, Pods, and Services). Check if it already has the permission:

```shell
oc get clusterrole agent-sandbox-controller -o json | grep 'sandboxes/finalizers'
```

If there is no output, patch the ClusterRole:

```shell
oc patch clusterrole agent-sandbox-controller --type=json \
  -p='[{"op":"add","path":"/rules/-","value":{"apiGroups":["agents.x-k8s.io"],"resources":["sandboxes/finalizers"],"verbs":["update"]}}]'
```

## 4. Create the SSH handshake secret

```shell
oc create secret generic openshell-ssh-handshake \
  --from-literal=secret=$(openssl rand -hex 32) \
  -n openshell
```

## 5. Deploy the OpenShell gateway with Helm

Install the Helm chart with OpenShift-specific overrides. TLS is disabled because the OpenShift Route terminates TLS at the edge. The hardcoded `fsGroup` and `runAsUser` are removed so OpenShift can assign UIDs from the namespace's allowed range.

> **Note:** The `latest` tag in the upstream `ghcr.io/nvidia/openshell` repository may not be up to date. Use a specific commit SHA as the image tag to ensure you get a working build.

```shell
helm install openshell deploy/helm/openshell -n openshell \
  --set server.disableTls=true \
  --set service.type=ClusterIP \
  --set server.sandboxNamespace=openshell \
  --set podSecurityContext.fsGroup=null \
  --set securityContext.runAsUser=null
```

If you are using dev images, add the image overrides with the desired tag:
8bfd3e1914a684094f472bce6d341706455288d7 is the current dev image hash

```shell
helm install openshell deploy/helm/openshell -n openshell \
--set server.disableTls=true \
--set service.type=ClusterIP \
--set server.sandboxNamespace=openshell \
--set image.repository=ghcr.io/nvidia/openshell/gateway \
--set image.tag=8bfd3e1914a684094f472bce6d341706455288d7 \
--set server.supervisorImage=ghcr.io/nvidia/openshell/supervisor:8bfd3e1914a684094f472bce6d341706455288d7 \
--set podSecurityContext.fsGroup=null \
--set securityContext.runAsUser=null
```

## 6. Create an OpenShift Route

Create an edge-terminated Route so the gateway is accessible over HTTPS:

```shell
oc create route edge openshell-gateway \
  --service=openshell \
  --port=grpc \
  -n openshell
```

## 7. Verify the deployment

```shell
oc get pods -n openshell
oc get svc -n openshell
oc get route -n openshell
```

The gateway pod (`openshell-0`) should be `Running` and `Ready`. Check the logs if there are issues:

```shell
oc logs openshell-0 -n openshell
```

## 8. Port-forward the gateway

In a separate terminal, start a port-forward so the local `openshell` CLI can reach the gateway:

```shell
oc port-forward svc/openshell 8080:8080 -n openshell
```

Keep this terminal running for the following steps.

## 9. Create an OpenClaw sandbox

In your main terminal (with the port-forward running):

```shell
OPENSHELL_GATEWAY_ENDPOINT=http://localhost:8080 openshell sandbox create --from openclaw
```

The output will include the sandbox name (e.g., `earnest-shrimp`). Note it for the next steps.

Verify the sandbox pod is running:

```shell
oc get pods -n openshell
oc get sandboxes.agents.x-k8s.io -n openshell
```

## 10. Configure OpenClaw

Run the interactive setup wizard inside the sandbox to configure your LLM provider (Anthropic, vLLM, etc.):

```shell
oc exec -it earnest-shrimp -n openshell -- openclaw configure
```

## 11. Start the OpenClaw gateway

Start the OpenClaw gateway process inside the sandbox:

```shell
oc exec earnest-shrimp -n openshell -- openclaw gateway --allow-unconfigured
```

## 12. Launch the OpenClaw dashboard UI

In a separate terminal, get the tokenized dashboard URL:

```shell
oc exec earnest-shrimp -n openshell -- openclaw dashboard --no-open
```

This prints a URL like `http://127.0.0.1:18789/#token=...`. Copy the token portion.

Start a port-forward to the sandbox's dashboard port:

```shell
oc port-forward earnest-shrimp 18789:18789 -n openshell
```

Open the URL in your browser, replacing the host with `localhost`:

```
http://localhost:18789/#token=<your-token>
```

To use a different local port:

```shell
oc port-forward <sandbox-name> 9999:18789 -n openshell
```

Then open `http://localhost:9999/#token=<your-token>`.

## Managing sandboxes

List all sandboxes:

```shell
oc get sandboxes.agents.x-k8s.io -n openshell
```

Delete a sandbox:

```shell
oc delete sandbox <sandbox-name> -n openshell
```

Check OpenClaw health inside a sandbox:

```shell
oc exec <sandbox-name> -n openshell -- openclaw health
```

View OpenClaw logs inside a sandbox:

```shell
oc exec <sandbox-name> -n openshell -- openclaw logs --follow
```

## Upgrading

```shell
helm upgrade openshell deploy/helm/openshell -n openshell \
  --set server.disableTls=true \
  --set service.type=ClusterIP \
  --set server.sandboxNamespace=openshell \
  --set image.repository=ghcr.io/nvidia/openshell/gateway \
  --set image.tag=<commit-sha-or-tag> \
  --set server.supervisorImage=ghcr.io/nvidia/openshell/supervisor:<commit-sha-or-tag> \
  --set podSecurityContext.fsGroup=null \
  --set securityContext.runAsUser=null
```

## Teardown

```shell
helm uninstall openshell -n openshell
oc delete route openshell-gateway -n openshell
oc delete secret openshell-ssh-handshake -n openshell
oc delete pvc -l app.kubernetes.io/instance=openshell -n openshell
```
