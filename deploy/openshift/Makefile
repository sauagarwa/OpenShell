# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# OpenShell on OpenShift — deployment automation
#
# Usage:
#   make deploy IMAGE_TAG=<sha>       Full deploy (namespace + CRD + SCC + secret + helm + route)
#   make upgrade IMAGE_TAG=<sha>      Helm upgrade with same overrides
#   make undeploy                     Full teardown
#   make status                       Show pods, routes, services
#   make logs                         Tail gateway logs
#   make sandbox-create               Create an OpenClaw sandbox
#   make openclaw-configure SANDBOX=<name>  Configure OpenClaw LLM provider
#   make openclaw-start SANDBOX=<name>      Start OpenClaw gateway in sandbox
#   make openclaw-ui SANDBOX=<name>         Launch OpenClaw dashboard UI
#   make sandbox-delete SANDBOX=<name>      Delete a sandbox
#   make images                       Build and push images to registry

NAMESPACE       ?= openshell
HELM_RELEASE    ?= openshell
HELM_CHART      ?= ../helm/openshell
IMAGE_REPO      ?= ghcr.io/nvidia/openshell
IMAGE_TAG       ?= latest
SANDBOX_IMAGE   ?= openclaw
OPENCLAW_PORT   ?= 18789
RUST_TARGET     ?= x86_64-unknown-linux-gnu
DOCKERFILE      ?= deploy/docker/Dockerfile.images
PROJECT_ROOT    ?= ../..
SANDBOX_CRD     ?= ../kube/manifests/agent-sandbox.yaml

GATEWAY_IMAGE   := $(IMAGE_REPO)/openshell-gateway:$(IMAGE_TAG)
SUPERVISOR_IMAGE := $(IMAGE_REPO)/openshell-supervisor:$(IMAGE_TAG)
PREBUILT_DIR    := ../docker/.build/prebuilt-binaries/amd64

HELM_OVERRIDES  := \
	--set server.disableTls=true \
	--set service.type=ClusterIP \
	--set server.sandboxNamespace=$(NAMESPACE) \
	--set image.repository=$(IMAGE_REPO)/openshell-gateway \
	--set image.tag=$(IMAGE_TAG) \
	--set server.supervisorImage=$(SUPERVISOR_IMAGE) \
	--set podSecurityContext.fsGroup=null \
	--set securityContext.runAsUser=null

.PHONY: deploy upgrade undeploy namespace sandbox-crd scc secret route status logs port-forward \
        sandbox-create sandbox-list sandbox-delete openclaw-configure openclaw-start openclaw-ui build images clean help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

deploy: namespace sandbox-crd scc secret helm-install route ## Full deploy: namespace + CRD + SCC + secret + helm + route
	@echo "Deploy complete. Run 'make status' to verify."

namespace:
	@oc get namespace $(NAMESPACE) >/dev/null 2>&1 || oc new-project $(NAMESPACE)

sandbox-crd: ## Install the Sandbox CRD and controller
	@oc get crd sandboxes.agents.x-k8s.io >/dev/null 2>&1 || oc apply -f $(SANDBOX_CRD)

scc: ## Grant privileged SCC and RBAC fixes for OpenShift
	oc adm policy add-scc-to-user privileged -z agent-sandbox-controller -n agent-sandbox-system
	oc adm policy add-scc-to-user privileged -z default -n $(NAMESPACE)
	@oc get clusterrole agent-sandbox-controller -o json | \
		grep -q 'sandboxes/finalizers' || \
		oc patch clusterrole agent-sandbox-controller --type=json \
			-p='[{"op":"add","path":"/rules/-","value":{"apiGroups":["agents.x-k8s.io"],"resources":["sandboxes/finalizers"],"verbs":["update"]}}]'

helm-install:
	helm install $(HELM_RELEASE) $(HELM_CHART) -n $(NAMESPACE) $(HELM_OVERRIDES)

upgrade: ## Helm upgrade with OpenShift overrides
	helm upgrade $(HELM_RELEASE) $(HELM_CHART) -n $(NAMESPACE) $(HELM_OVERRIDES)

undeploy: ## Full teardown: helm uninstall + route + secret + PVCs
	-helm uninstall $(HELM_RELEASE) -n $(NAMESPACE)
	-oc delete route openshell-gateway -n $(NAMESPACE)
	-oc delete secret openshell-ssh-handshake -n $(NAMESPACE)
	-oc delete pvc -l app.kubernetes.io/instance=$(HELM_RELEASE) -n $(NAMESPACE)
	@echo "Teardown complete."

secret: ## Create SSH handshake secret
	@oc get secret openshell-ssh-handshake -n $(NAMESPACE) >/dev/null 2>&1 || \
		oc create secret generic openshell-ssh-handshake \
			--from-literal=secret=$$(openssl rand -hex 32) \
			-n $(NAMESPACE)

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
# Build
# ---------------------------------------------------------------------------

build: ## Cross-compile gateway + supervisor for linux/amd64
	cd $(PROJECT_ROOT) && cargo zigbuild --release --target $(RUST_TARGET) \
		-p openshell-server -p openshell-sandbox
	@mkdir -p $(PREBUILT_DIR)
	cp $(PROJECT_ROOT)/target/$(RUST_TARGET)/release/openshell-gateway $(PREBUILT_DIR)/
	cp $(PROJECT_ROOT)/target/$(RUST_TARGET)/release/openshell-sandbox $(PREBUILT_DIR)/
	@echo "Binaries staged at $(PREBUILT_DIR)/"

images: build ## Build and push gateway + supervisor images
	cd $(PROJECT_ROOT) && docker buildx build --platform linux/amd64 \
		--target gateway -t $(GATEWAY_IMAGE) --push -f $(DOCKERFILE) .
	cd $(PROJECT_ROOT) && docker buildx build --platform linux/amd64 \
		--target supervisor -t $(SUPERVISOR_IMAGE) --push -f $(DOCKERFILE) .
	@echo "Pushed $(GATEWAY_IMAGE) and $(SUPERVISOR_IMAGE)"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

clean: ## Delete PVCs and stale sandbox resources
	-oc delete pvc -l app.kubernetes.io/instance=$(HELM_RELEASE) -n $(NAMESPACE)
	@echo "Cleaned up PVCs."
