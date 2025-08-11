# Makefile for testing of Pulsar deployment locally on Colima/K3s

PROFILE_NAME := pulsar
HELM_RELEASE := mypulsar
NAMESPACE := pulsar
CONTEXT_NAME := colima-$(PROFILE_NAME)
COLIMA_ARCH := x86_64
COLIMA_CPU := 4
COLIMA_MEMORY := 8
COLIMA_DISK := 50

.PHONY: help setup-deps setup-colima setup-images setup-pv setup-pulsar test-job debug-status debug-logs debug-job debug-port-forward clean-pvc clean-pv clean-pulsar clean-colima

help:
	@echo "Test Pulsar deployment locally using Colima on macOS."
	@echo ""
	@echo "Quick Start:"
	@echo "  1. make setup-deps setup-colima setup-images"
	@echo "  2. make setup-pv setup-pulsar"
	@echo "  3. make test-job"
	@echo "  4. make clean-pulsar clean-pv clean-colima"
	@echo ""
	@echo "Setup Commands:"
	@echo "  setup-deps       - Check required dependencies"
	@echo "  setup-colima     - Create and start Colima profile with Kubernetes"
	@echo "  setup-images     - Pre-pull required Docker images"
	@echo "  setup-pv         - Apply local persistent volumes"
	@echo "  setup-pulsar     - Deploy Pulsar with Helm"
	@echo ""
	@echo "Testing Commands:"
	@echo "  test-job         - Submit and monitor a hello world job"
	@echo ""
	@echo "Debug & Management Commands:"
	@echo "  debug-status     - Show deployment status"
	@echo "  debug-logs       - Show Pulsar logs"
	@echo "  debug-job        - Check specific job status (use JOB_ID=xxx)"
	@echo "  debug-port-forward - Port forward to access Pulsar locally"
	@echo ""
	@echo "Cleanup Commands:"
	@echo "  clean-pulsar     - Remove Pulsar deployment (fast, no PV wait)"
	@echo "  clean-pvc        - Force remove stuck PVCs only"
	@echo "  clean-pv         - Remove persistent volumes and PVCs"
	@echo "  clean-colima     - Stop and delete Colima profile"

setup-deps:
	@echo "🔍 Checking dependencies..."
	@command -v brew >/dev/null 2>&1 || { echo "❌ Homebrew not found. Please install it first."; exit 1; }
	@command -v colima >/dev/null 2>&1 || { echo "❌ Colima not found. Run: brew install colima"; exit 1; }
	@command -v helm >/dev/null 2>&1 || { echo "❌ Helm not found. Run: brew install helm"; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl not found. Run: brew install kubectl"; exit 1; }
	@echo "🔍 Checking for lima-additional-guestagents..."
	@if ! brew list lima-additional-guestagents >/dev/null 2>&1; then \
		echo "📦 Installing lima-additional-guestagents..."; \
		brew install lima-additional-guestagents; \
		echo "✅ lima-additional-guestagents installed"; \
	else \
		echo "✅ lima-additional-guestagents already installed"; \
	fi
	@echo "✅ All dependencies are available"

setup-colima: setup-deps
	@echo "📦 Setting up Colima profile '$(PROFILE_NAME)'..."
	@if colima list | grep -q "^$(PROFILE_NAME)"; then \
		echo "🧹 Found existing '$(PROFILE_NAME)' profile, cleaning up..."; \
		colima stop $(PROFILE_NAME) 2>/dev/null || true; \
		colima delete $(PROFILE_NAME) 2>/dev/null || true; \
	fi
	@echo "🚀 Creating Colima profile with Kubernetes..."
	@echo "➜ colima start $(PROFILE_NAME) --arch $(COLIMA_ARCH) --cpu $(COLIMA_CPU) --memory $(COLIMA_MEMORY) --disk $(COLIMA_DISK) --kubernetes"
	colima start $(PROFILE_NAME) --arch $(COLIMA_ARCH) --cpu $(COLIMA_CPU) --memory $(COLIMA_MEMORY) --disk $(COLIMA_DISK) --kubernetes
	@echo "✅ Colima profile '$(PROFILE_NAME)' started successfully"
	@echo "🔧 Setting Kubernetes context..."
	@echo "➜ kubectl config use-context $(CONTEXT_NAME)"
	kubectl config use-context $(CONTEXT_NAME)
	@echo "✅ Switched to context: $(CONTEXT_NAME)"
	@echo "➜ kubectl config current-context"
	kubectl config current-context

setup-images:
	@echo "🐳 Pre-pulling required Docker images ($(COLIMA_ARCH))..."
	@$(MAKE) --no-print-directory _retry_pull IMAGE=galaxy/pulsar-kubernetes:0.15.7
	@$(MAKE) --no-print-directory _retry_pull IMAGE=docker:dind

_retry_pull:
	@echo "📥 Pulling $(IMAGE)..."
	@max_retries=3; \
	retry=0; \
	while [ $$retry -lt $$max_retries ]; do \
		echo "📥 Attempt $$((retry + 1))/$$max_retries for $(IMAGE)..."; \
		if docker pull --platform linux/amd64 $(IMAGE); then \
			echo "✅ Successfully pulled $(IMAGE)"; \
			exit 0; \
		else \
			echo "⚠️  Failed to pull $(IMAGE) (attempt $$((retry + 1))/$$max_retries)"; \
			retry=$$((retry + 1)); \
			if [ $$retry -lt $$max_retries ]; then \
				echo "⏳ Waiting 10 seconds before retry..."; \
				sleep 10; \
			fi; \
		fi; \
	done; \
	echo "❌ Failed to pull $(IMAGE) after $$max_retries attempts"; \
	echo "ℹ️  Kubernetes will pull during deployment (may take longer)"; \
	exit 0

setup-pv:
	@echo "🔧 Creating and applying local persistent volumes..."
	@{ \
		echo 'apiVersion: v1'; \
		echo 'kind: PersistentVolume'; \
		echo 'metadata:'; \
		echo '  name: pulsar-data-pv'; \
		echo '  labels:'; \
		echo '    type: local'; \
		echo 'spec:'; \
		echo '  storageClassName: local-path'; \
		echo '  capacity:'; \
		echo '    storage: 20Gi'; \
		echo '  accessModes:'; \
		echo '    - ReadWriteOnce'; \
		echo '  hostPath:'; \
		echo '    path: "/tmp/pulsar-data"'; \
		echo '  persistentVolumeReclaimPolicy: Retain'; \
	} > /tmp/local-pvs.yaml
	@echo "➜ kubectl apply -f /tmp/local-pvs.yaml"
	@kubectl apply -f /tmp/local-pvs.yaml
	@rm -f /tmp/local-pvs.yaml
	@echo "✅ Local PVs created"

setup-pulsar:
	@echo "🚀 Creating values file and deploying Pulsar with Helm..."
	@{ \
		echo '# Local testing values for Colima/K3s + ARM64/Apple Silicon'; \
		echo 'image:'; \
		echo '  repository: galaxy/pulsar-kubernetes'; \
		echo '  pullPolicy: IfNotPresent'; \
		echo '  tag: ""'; \
		echo 'podSecurityContext:'; \
		echo '  runAsUser: 0'; \
		echo '  runAsGroup: 0'; \
		echo '  fsGroup: 1001'; \
		echo 'securityContext:'; \
		echo '  runAsUser: 0'; \
		echo '  runAsGroup: 0'; \
		echo 'persistence:'; \
		echo '  enabled: true'; \
		echo '  storageClass: "local-path"'; \
		echo '  accessModes:'; \
		echo '    - ReadWriteOnce'; \
		echo '  size: 20Gi'; \
		echo '  mountPath: "/pulsar/files"'; \
		echo 'refdata:'; \
		echo '  enabled: false'; \
		echo 'api_key: "test-api-key-for-local-development"'; \
		echo 'service:'; \
		echo '  type: NodePort'; \
		echo '  port: 8913'; \
		echo 'ingress:'; \
		echo '  enabled: false'; \
	} > /tmp/values-local.yaml
	@echo "➜ helm install $(HELM_RELEASE) ./pulsar -n $(NAMESPACE) --create-namespace -f /tmp/values-local.yaml"
	@helm install $(HELM_RELEASE) ./pulsar -n $(NAMESPACE) --create-namespace -f /tmp/values-local.yaml
	@rm -f /tmp/values-local.yaml
	@echo "⏳ Waiting for deployment to be ready..."
	@echo "➜ kubectl wait --for=condition=available --timeout=300s -n $(NAMESPACE) deployment/$(HELM_RELEASE)"
	@kubectl wait --for=condition=available --timeout=300s -n $(NAMESPACE) deployment/$(HELM_RELEASE) || true
	@echo "✅ Pulsar deployment completed in namespace '$(NAMESPACE)'!"

test-job:
	@echo "🎯 Testing Pulsar Job Submission"
	@pkill -f "kubectl port-forward.*8913" 2>/dev/null || true
	@sleep 2
	@echo "🔗 Starting port forward..."
	@nohup kubectl port-forward -n $(NAMESPACE) svc/$(HELM_RELEASE) 8913:8913 </dev/null >/tmp/pf.log 2>&1 &
	@PF_PID=$$!; \
	echo "⏳ Waiting for port forward to establish..."; \
	port_forward_established=false; \
	for i in {1..10}; do \
		if curl -s http://localhost:8913 >/dev/null 2>&1; then \
			echo "✅ Port forward ready"; \
			port_forward_established=true; \
			break; \
		fi; \
		sleep 1; \
	done; \
	if [ "$$port_forward_established" = "false" ]; then \
		echo "❌ Failed to establish port forward to Pulsar service"; \
		pkill -f "kubectl port-forward.*8913" 2>/dev/null || true; \
		exit 1; \
	fi; \
	job_id="test-job-$$(date +%s)"; \
	token="test-api-key-for-local-development"; \
	command="echo 'Hello World from Pulsar!' && echo 'Current time: $$(date)' && echo 'Job ID: $$job_id' && sleep 2 && echo 'SUCCESS: Job completed!'"; \
	echo "🆔 Job ID: $$job_id"; \
	echo ""; \
	echo "🔧 Step 1: Setting up job..."; \
	setup_response=$$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST \
		-H "Content-Type: application/json" \
		-d "{\"command_line\": \"$$command\", \"job_config\": {\"runner\": \"local\"}}" \
		"http://localhost:8913/jobs?job_id=$$job_id&private_token=$$token" 2>/dev/null); \
	setup_status=$$(echo "$$setup_response" | grep "HTTP_STATUS:" | cut -d: -f2); \
	if [ "$$setup_status" != "200" ]; then \
		echo "❌ Job setup failed with HTTP status: $$setup_status"; \
		pkill -f "kubectl port-forward.*8913" 2>/dev/null || kill $$PF_PID 2>/dev/null || true; \
		exit 1; \
	fi; \
	echo "✅ Job setup successful!"; \
	echo ""; \
	echo "🚀 Step 2: Submitting job..."; \
	encoded_command=$$(echo "$$command" | sed 's/ /%20/g' | sed 's/&/%26/g' | sed 's/"/%22/g' | sed "s/'/%27/g"); \
	submit_response=$$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST \
		"http://localhost:8913/jobs/$$job_id/submit?command_line=$$encoded_command&private_token=$$token" 2>/dev/null); \
	submit_status=$$(echo "$$submit_response" | grep "HTTP_STATUS:" | cut -d: -f2); \
	if [ "$$submit_status" = "000" ] || [ -z "$$submit_status" ] || [ "$$submit_status" != "200" ]; then \
		echo "❌ Job submission failed with HTTP status: $$submit_status"; \
		if [ "$$submit_status" = "000" ]; then \
			echo "   (000 indicates connection failure - is Pulsar running in the correct namespace?)"; \
		fi; \
		pkill -f "kubectl port-forward.*8913" 2>/dev/null || kill $$PF_PID 2>/dev/null || true; \
		exit 1; \
	fi; \
	echo "✅ Submit status: $$submit_status"; \
	echo ""; \
	echo "⏳ Step 3: Monitoring job (15 seconds)..."; \
	job_success=false; \
	for i in {1..5}; do \
		sleep 3; \
		status_response=$$(curl -s "http://localhost:8913/jobs/$$job_id/status?private_token=$$token" 2>/dev/null); \
		if [ -n "$$status_response" ] && echo "$$status_response" | grep -q '"status"'; then \
			status=$$(printf '%s\n' "$$status_response" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data.get('status','unknown'))" 2>/dev/null || echo "unknown"); \
			complete=$$(printf '%s\n' "$$status_response" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data.get('complete','false'))" 2>/dev/null || echo "false"); \
		else \
			status="no-response"; \
			complete="false"; \
		fi; \
		echo "[$$i/5] Status: $$status, Complete: $$complete"; \
		if [ "$$complete" = "true" ]; then \
			echo "🎉 Job completed!"; \
			job_success=true; \
			break; \
		fi; \
	done; \
	echo ""; \
	echo "📋 Final job results:"; \
	curl -s "http://localhost:8913/jobs/$$job_id/status?private_token=$$token" > /tmp/job_status.json 2>/dev/null; \
	if [ -s /tmp/job_status.json ] && grep -q '"status"' /tmp/job_status.json; then \
		final_status=$$(python3 -c "import json; data=json.load(open('/tmp/job_status.json')); print(data.get('status','unknown'))" 2>/dev/null || echo 'unknown'); \
		echo "Status: $$final_status"; \
		echo "Return Code: $$(python3 -c "import json; data=json.load(open('/tmp/job_status.json')); print(data.get('returncode','N/A'))" 2>/dev/null || echo 'N/A')"; \
		job_output=$$(python3 -c "import json; data=json.load(open('/tmp/job_status.json')); print(data.get('job_stdout','') or data.get('stdout',''))" 2>/dev/null); \
		if [ -n "$$job_output" ]; then \
			echo "Job Output:"; \
			echo "$$job_output"; \
		else \
			echo "No job output available"; \
		fi; \
		if [ "$$final_status" = "complete" ] || [ "$$final_status" = "finished" ]; then \
			job_success=true; \
		fi; \
	else \
		echo "❌ Could not retrieve job status or invalid response"; \
		job_success=false; \
	fi; \
	rm -f /tmp/job_status.json; \
	pkill -f "kubectl port-forward.*8913" 2>/dev/null || kill $$PF_PID 2>/dev/null || true; \
	echo ""; \
	if [ "$$job_success" = "true" ]; then \
		echo "✅ Test job completed successfully! Job ID: $$job_id"; \
	else \
		echo "❌ Test job failed! Job ID: $$job_id"; \
		echo "   Check that Pulsar is running in the correct namespace and accessible."; \
		exit 1; \
	fi

debug-job:
	@echo "🔍 Checking job status..."
	@if [ -z "$(JOB_ID)" ]; then \
		echo "❌ Please provide JOB_ID: make debug-job JOB_ID=your-job-id"; \
		exit 1; \
	fi
	@echo "🔗 Starting port forward..."
	@nohup kubectl port-forward -n $(NAMESPACE) svc/$(HELM_RELEASE) 8913:8913 </dev/null >/tmp/pf.log 2>&1 &
	@PF_PID=$$!; \
	echo "⏳ Waiting for port forward to establish..."; \
	for i in {1..10}; do \
		if curl -s http://localhost:8913 >/dev/null 2>&1; then \
			echo "✅ Port forward ready"; \
			break; \
		fi; \
		sleep 1; \
	done; \
	echo "Job ID: $(JOB_ID)"; \
	response=$$(curl -s "http://localhost:8913/jobs/$(JOB_ID)/status?private_token=test-api-key-for-local-development" 2>/dev/null); \
	echo "Status response:"; \
	echo "$$response" | python3 -m json.tool 2>/dev/null || echo "$$response"; \
	pkill -f "kubectl port-forward.*8913" 2>/dev/null || kill $$PF_PID 2>/dev/null || true

debug-status:
	@echo "📋 Deployment Status:"
	@echo "Current context: $$(kubectl config current-context)"
	@echo "Namespace: $(NAMESPACE)"
	@echo ""
	@echo "Pods:"
	@echo "➜ kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=pulsar"
	kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=pulsar
	@echo ""
	@echo "PVCs:"
	@echo "➜ kubectl get pvc -n $(NAMESPACE)"
	kubectl get pvc -n $(NAMESPACE)
	@echo ""
	@echo "Services:"
	@echo "➜ kubectl get svc -n $(NAMESPACE)"
	kubectl get svc -n $(NAMESPACE)

debug-logs:
	@echo "📖 Showing Pulsar logs..."
	@echo "➜ kubectl logs -n $(NAMESPACE) -l app.kubernetes.io/name=pulsar -c pulsar --tail=20"
	kubectl logs -n $(NAMESPACE) -l app.kubernetes.io/name=pulsar -c pulsar --tail=20

debug-port-forward:
	@echo "🔗 Port forwarding to Pulsar (http://localhost:8913)..."
	@echo "Press Ctrl+C to stop"
	@echo "➜ kubectl port-forward -n $(NAMESPACE) svc/$(HELM_RELEASE) 8913:8913"
	kubectl port-forward -n $(NAMESPACE) svc/$(HELM_RELEASE) 8913:8913

clean-pvc:
	@echo "🧹 Force cleaning PVCs in namespace '$(NAMESPACE)'..."
	@echo "➜ kubectl get pvc -n $(NAMESPACE) -o name | xargs -I {} kubectl patch -n $(NAMESPACE) {} -p '{\"metadata\":{\"finalizers\":null}}' --type=merge"
	@kubectl get pvc -n $(NAMESPACE) -o name | xargs -I {} kubectl patch -n $(NAMESPACE) {} -p '{"metadata":{"finalizers":null}}' --type=merge || true
	@echo "➜ kubectl delete pvc -n $(NAMESPACE) --all --force --grace-period=0"
	@kubectl delete pvc -n $(NAMESPACE) --all --force --grace-period=0 || true
	@echo "✅ PVCs force cleaned in namespace '$(NAMESPACE)'"

clean-pv:
	@echo "🧹 Force cleaning PVCs and PVs..."
	@echo "➜ kubectl get pvc -n $(NAMESPACE) -o name | xargs -I {} kubectl patch -n $(NAMESPACE) {} -p '{\"metadata\":{\"finalizers\":null}}' --type=merge"
	@kubectl get pvc -n $(NAMESPACE) -o name | xargs -I {} kubectl patch -n $(NAMESPACE) {} -p '{"metadata":{"finalizers":null}}' --type=merge || true
	@echo "➜ kubectl delete pvc -n $(NAMESPACE) --all --force --grace-period=0"
	@kubectl delete pvc -n $(NAMESPACE) --all --force --grace-period=0 || true
	@echo "➜ kubectl delete pv pulsar-data-pv --force --grace-period=0"
	@kubectl delete pv pulsar-data-pv --force --grace-period=0 || true
	@echo "✅ PVCs and PVs force cleaned"

clean-pulsar:
	@echo "🧹 Removing Pulsar deployment from namespace '$(NAMESPACE)'..."
	@if helm list -n $(NAMESPACE) -q | grep -q "^$(HELM_RELEASE)$$"; then \
		echo "➜ helm uninstall $(HELM_RELEASE) -n $(NAMESPACE)"; \
		helm uninstall $(HELM_RELEASE) -n $(NAMESPACE); \
		echo "✅ Pulsar deployment removed from namespace '$(NAMESPACE)'"; \
	else \
		echo "ℹ️  Pulsar deployment not found in namespace '$(NAMESPACE)' (already removed)"; \
	fi
	@echo "ℹ️  Use 'make clean-pv' to clean persistent volumes if needed"

clean-colima:
	@echo "🧹 Cleaning up namespace '$(NAMESPACE)'..."
	@echo "➜ kubectl delete namespace $(NAMESPACE) --force --grace-period=0"
	@kubectl delete namespace $(NAMESPACE) --force --grace-period=0 2>/dev/null || true
	@echo "🧹 Stopping and removing Colima profile..."
	@echo "➜ colima stop $(PROFILE_NAME)"
	colima stop $(PROFILE_NAME)
	@echo "➜ colima delete $(PROFILE_NAME)"
	colima delete $(PROFILE_NAME)
	@echo "✅ Colima profile '$(PROFILE_NAME)' removed"
	@echo "🧹 Removing kubectl context '$(CONTEXT_NAME)'..."
	@echo "➜ kubectl config delete-context $(CONTEXT_NAME)"
	@kubectl config delete-context $(CONTEXT_NAME) 2>/dev/null || true
	@echo "✅ kubectl context '$(CONTEXT_NAME)' removed"
