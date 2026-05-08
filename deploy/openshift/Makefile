# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# OpenShell on OpenShift — deployment automation
#
# Usage:
#   make deploy                       Full deploy (namespace + CRD + SCC + helm + route)
#   make upgrade                      Helm upgrade with same overrides
#   make undeploy                     Full teardown
#   make status                       Show pods, routes, services
#   make logs                         Tail gateway logs
#   make sandbox-create               Create an OpenClaw sandbox
#   make openclaw-configure SANDBOX=<name>  Configure OpenClaw LLM provider
#   make openclaw-start SANDBOX=<name>      Start OpenClaw gateway in sandbox
#   make openclaw-ui SANDBOX=<name>         Launch OpenClaw dashboard UI
#   make sandbox-delete SANDBOX=<name>      Delete a sandbox

NAMESPACE       ?= openshell
HELM_RELEASE    ?= openshell
HELM_CHART      ?= oci://ghcr.io/nvidia/openshell/helm-chart
HELM_VERSION    ?= 0.0.0-dev
SANDBOX_IMAGE   ?= openclaw
OPENCLAW_PORT   ?= 18789
SANDBOX_CRD     ?= https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.4.3/manifest.yaml

HELM_OVERRIDES  := \
	--set pkiInitJob.enabled=false \
	--set server.disableTls=true \
	--set podSecurityContext.fsGroup=null \
	--set securityContext.runAsUser=null

.PHONY: deploy upgrade undeploy namespace sandbox-crd scc route status logs port-forward \
        sandbox-create sandbox-list sandbox-delete openclaw-configure openclaw-start openclaw-ui clean help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

deploy: namespace sandbox-crd scc helm-install route ## Full deploy: namespace + CRD + SCC + helm + route
	@echo "Deploy complete. Run 'make status' to verify."

namespace:
	@oc get namespace $(NAMESPACE) >/dev/null 2>&1 || oc create ns $(NAMESPACE)

sandbox-crd: ## Install the Sandbox CRD and controller
	@oc get crd sandboxes.agents.x-k8s.io >/dev/null 2>&1 || oc apply -f $(SANDBOX_CRD)

scc: ## Grant privileged SCC for sandbox pods
	oc adm policy add-scc-to-user privileged -z default -n $(NAMESPACE)

helm-install:
	helm install $(HELM_RELEASE) $(HELM_CHART) --version $(HELM_VERSION) -n $(NAMESPACE) $(HELM_OVERRIDES)

upgrade: ## Helm upgrade with OpenShift overrides
	helm upgrade $(HELM_RELEASE) $(HELM_CHART) --version $(HELM_VERSION) -n $(NAMESPACE) $(HELM_OVERRIDES)

undeploy: ## Full teardown: helm uninstall + route + PVCs
	-helm uninstall $(HELM_RELEASE) -n $(NAMESPACE)
	-oc delete route openshell-gateway -n $(NAMESPACE)
	-oc delete pvc -l app.kubernetes.io/instance=$(HELM_RELEASE) -n $(NAMESPACE)
	@echo "Teardown complete."

route: ## Create OpenShift edge-terminated Route
	@oc get route openshell-gateway -n $(NAMESPACE) >/dev/null 2>&1 || \
		oc create route edge openshell-gateway \
			--service=$(HELM_RELEASE) \
			--port=grpc \
			-n $(NAMESPACE)

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

status: ## Show pods, routes, services, sandboxes
	@echo "=== Pods ==="
	@oc get pods -n $(NAMESPACE)
	@echo "\n=== Services ==="
	@oc get svc -n $(NAMESPACE)
	@echo "\n=== Routes ==="
	@oc get route -n $(NAMESPACE)
	@echo "\n=== Sandboxes ==="
	@-oc get sandboxes.agents.x-k8s.io -n $(NAMESPACE) 2>/dev/null || echo "(none)"

logs: ## Tail gateway logs
	oc logs -f $(HELM_RELEASE)-0 -n $(NAMESPACE)

# ---------------------------------------------------------------------------
# Sandbox operations
# ---------------------------------------------------------------------------

port-forward: ## Port-forward gateway for local CLI access
	oc port-forward svc/$(HELM_RELEASE) 8080:8080 -n $(NAMESPACE)

sandbox-create: ## Create an OpenClaw sandbox (run port-forward first)
	OPENSHELL_GATEWAY_ENDPOINT=http://localhost:8080 openshell sandbox create --from $(SANDBOX_IMAGE)

sandbox-list: ## List sandboxes
	@oc get sandboxes.agents.x-k8s.io -n $(NAMESPACE)

sandbox-delete: ## Delete a sandbox (SANDBOX=<name>)
	@if [ -z "$(SANDBOX)" ]; then echo "Usage: make sandbox-delete SANDBOX=<sandbox-name>"; exit 1; fi
	oc delete sandbox $(SANDBOX) -n $(NAMESPACE)

openclaw-configure: ## Configure OpenClaw in sandbox (SANDBOX=<name>)
	@if [ -z "$(SANDBOX)" ]; then echo "Usage: make openclaw-configure SANDBOX=<sandbox-name>"; exit 1; fi
	oc exec -it $(SANDBOX) -n $(NAMESPACE) -- openclaw configure

openclaw-start: ## Start OpenClaw gateway in sandbox (SANDBOX=<name>)
	@if [ -z "$(SANDBOX)" ]; then echo "Usage: make openclaw-start SANDBOX=<sandbox-name>"; exit 1; fi
	oc exec $(SANDBOX) -n $(NAMESPACE) -- openclaw gateway --allow-unconfigured

openclaw-ui: ## Launch OpenClaw UI (SANDBOX=<name> [OPENCLAW_PORT=18789])
	@if [ -z "$(SANDBOX)" ]; then echo "Usage: make openclaw-ui SANDBOX=<sandbox-name> [OPENCLAW_PORT=port]"; exit 1; fi
	@echo "Fetching dashboard URL from $(SANDBOX)..."
	@URL=$$(oc exec $(SANDBOX) -n $(NAMESPACE) -- openclaw dashboard --no-open 2>&1 | grep -o 'http://[^ ]*'); \
		LOCAL_URL=$$(echo "$$URL" | sed 's|http://[^/]*|http://localhost:$(OPENCLAW_PORT)|'); \
		echo "\nOpen in your browser:\n  $$LOCAL_URL\n"; \
		echo "Starting port-forward on localhost:$(OPENCLAW_PORT)..."; \
		oc port-forward $(SANDBOX) $(OPENCLAW_PORT):18789 -n $(NAMESPACE)

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

clean: ## Delete PVCs and stale sandbox resources
	-oc delete pvc -l app.kubernetes.io/instance=$(HELM_RELEASE) -n $(NAMESPACE)
	@echo "Cleaned up PVCs."
