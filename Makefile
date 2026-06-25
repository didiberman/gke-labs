# =============================================================================
# GKE Labs — Makefile
# =============================================================================
#
# All targets operate on the dev environment by default.
# Override with: make plan ENV=staging
#
# Prerequisites:
#   • gcloud CLI authenticated  (gcloud auth application-default login)
#   • terraform >= 1.9.8       (managed by tfenv via .terraform-version)
#   • helm >= 3.15
#   • docker + docker compose
#   • kubectl (configured by `make connect`)
#
# Usage:
#   make help          — list all targets
#   make setup         — bootstrap GCP project prerequisites
#   make init          — initialise Terraform
#   make plan          — show Terraform execution plan
#   make apply         — apply Terraform changes
#   make connect       — configure kubectl for the dev cluster
#
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

ENV            ?= dev
TF_DIR         := terraform/environments/$(ENV)
CHARTS_DIR     := charts
LOCAL_DIR      := local
SCRIPTS_DIR    := scripts

# Helm release names
PAYMENTS_RELEASE      := payments-api
OBSERVABILITY_RELEASE := observability

# Helm namespaces
PAYMENTS_NS      := payments
OBSERVABILITY_NS := observability

# Colours for pretty output
BOLD  := \033[1m
RESET := \033[0m
GREEN := \033[32m
CYAN  := \033[36m
YELLOW := \033[33m

# ---------------------------------------------------------------------------
# Phony declarations
# ---------------------------------------------------------------------------

.PHONY: help \
        setup \
        init plan apply destroy \
        connect \
        deploy-app deploy-observability deploy-all \
        lint-tf lint-helm lint \
        local-up local-down local-logs \
        fmt validate \
        clean

# ---------------------------------------------------------------------------
# Default target
# ---------------------------------------------------------------------------

.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Help — auto-generated from ## comments
# ---------------------------------------------------------------------------

help: ## Show this help message
	@echo ""
	@echo "$(BOLD)GKE Labs — available targets$(RESET)"
	@echo "$(CYAN)────────────────────────────────────────────────────────────────$(RESET)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-22s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "  Override the environment with $(BOLD)ENV=<env>$(RESET) (default: dev)"
	@echo "  Example: $(BOLD)make plan ENV=staging$(RESET)"
	@echo ""

# ---------------------------------------------------------------------------
# GCP Bootstrap
# ---------------------------------------------------------------------------

setup: ## Bootstrap GCP project: enable APIs, create service accounts, set up remote state bucket
	@echo "$(BOLD)▶ Bootstrapping GCP project prerequisites (ENV=$(ENV))…$(RESET)"
	@bash $(SCRIPTS_DIR)/setup-gcp.sh $(ENV)

# ---------------------------------------------------------------------------
# Terraform
# ---------------------------------------------------------------------------

init: ## Initialise Terraform — download providers and configure backend
	@echo "$(BOLD)▶ Initialising Terraform for ENV=$(ENV)…$(RESET)"
	@terraform -chdir=$(TF_DIR) init -upgrade

plan: ## Show Terraform execution plan (no changes applied)
	@echo "$(BOLD)▶ Running Terraform plan for ENV=$(ENV)…$(RESET)"
	@terraform -chdir=$(TF_DIR) plan -out=tfplan

apply: ## Apply Terraform changes (prompts for confirmation)
	@echo "$(BOLD)▶ Applying Terraform changes for ENV=$(ENV)…$(RESET)"
	@terraform -chdir=$(TF_DIR) apply tfplan

apply-auto: ## Apply Terraform changes WITHOUT confirmation (CI use only)
	@echo "$(YELLOW)$(BOLD)⚠  Auto-approving Terraform apply for ENV=$(ENV)…$(RESET)"
	@terraform -chdir=$(TF_DIR) apply -auto-approve

destroy: ## Tear down all infrastructure for the current environment
	@echo "$(YELLOW)$(BOLD)⚠  Tearing down infrastructure for ENV=$(ENV)…$(RESET)"
	@bash $(SCRIPTS_DIR)/teardown.sh $(ENV)

fmt: ## Format all Terraform files in-place
	@echo "$(BOLD)▶ Formatting Terraform files…$(RESET)"
	@terraform fmt -recursive terraform/

validate: ## Validate Terraform configuration syntax and provider schemas
	@echo "$(BOLD)▶ Validating Terraform configuration for ENV=$(ENV)…$(RESET)"
	@terraform -chdir=$(TF_DIR) validate

# ---------------------------------------------------------------------------
# Kubectl / Cluster Access
# ---------------------------------------------------------------------------

connect: ## Configure kubectl credentials for the dev GKE cluster
	@echo "$(BOLD)▶ Fetching GKE credentials for ENV=$(ENV)…$(RESET)"
	@bash $(SCRIPTS_DIR)/connect.sh $(ENV)

# ---------------------------------------------------------------------------
# Helm — Deploy Application Services
# ---------------------------------------------------------------------------

deploy-app: ## Deploy (or upgrade) the payments-api Helm chart to the cluster
	@echo "$(BOLD)▶ Deploying $(PAYMENTS_RELEASE) chart…$(RESET)"
	@helm upgrade --install $(PAYMENTS_RELEASE) \
		$(CHARTS_DIR)/payments-api \
		--namespace $(PAYMENTS_NS) \
		--create-namespace \
		--values $(CHARTS_DIR)/payments-api/values.yaml \
		--values $(CHARTS_DIR)/payments-api/values-$(ENV).yaml \
		--atomic \
		--timeout 5m \
		--wait

deploy-observability: ## Deploy (or upgrade) the observability stack (Prometheus, Grafana, Loki)
	@echo "$(BOLD)▶ Deploying $(OBSERVABILITY_RELEASE) chart…$(RESET)"
	@helm upgrade --install $(OBSERVABILITY_RELEASE) \
		$(CHARTS_DIR)/observability \
		--namespace $(OBSERVABILITY_NS) \
		--create-namespace \
		--values $(CHARTS_DIR)/observability/values.yaml \
		--values $(CHARTS_DIR)/observability/values-$(ENV).yaml \
		--atomic \
		--timeout 10m \
		--wait

deploy-all: deploy-app deploy-observability ## Deploy all Helm charts to the cluster
	@echo "$(BOLD)✓ All charts deployed successfully for ENV=$(ENV)$(RESET)"

# ---------------------------------------------------------------------------
# Linting
# ---------------------------------------------------------------------------

lint-tf: ## Check Terraform files are correctly formatted (non-destructive)
	@echo "$(BOLD)▶ Linting Terraform files…$(RESET)"
	@terraform fmt -check -recursive terraform/
	@echo "$(GREEN)✓ Terraform formatting OK$(RESET)"

lint-helm: ## Lint all Helm charts in the charts/ directory
	@echo "$(BOLD)▶ Linting Helm charts…$(RESET)"
	@for chart in $(CHARTS_DIR)/*/; do \
		echo "  Linting $$chart…"; \
		helm lint "$$chart"; \
	done
	@echo "$(GREEN)✓ Helm lint OK$(RESET)"

lint: lint-tf lint-helm ## Run all linters (Terraform + Helm)

# ---------------------------------------------------------------------------
# Local Development (Docker Compose)
# ---------------------------------------------------------------------------

local-up: ## Start local development environment using Docker Compose
	@echo "$(BOLD)▶ Starting local dev environment…$(RESET)"
	@docker compose -f $(LOCAL_DIR)/docker-compose.yml up -d
	@echo "$(GREEN)✓ Local environment is up. Services:$(RESET)"
	@docker compose -f $(LOCAL_DIR)/docker-compose.yml ps

local-down: ## Stop and remove local development containers
	@echo "$(BOLD)▶ Stopping local dev environment…$(RESET)"
	@docker compose -f $(LOCAL_DIR)/docker-compose.yml down

local-logs: ## Tail logs from all local Docker Compose services
	@echo "$(BOLD)▶ Tailing local service logs (Ctrl+C to stop)…$(RESET)"
	@docker compose -f $(LOCAL_DIR)/docker-compose.yml logs -f

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

clean: ## Remove local Terraform artefacts (.terraform/, tfplan files)
	@echo "$(BOLD)▶ Cleaning local Terraform artefacts…$(RESET)"
	@find terraform/ -name '.terraform' -type d -exec rm -rf {} + 2>/dev/null || true
	@find terraform/ -name 'tfplan' -type f -delete 2>/dev/null || true
	@find terraform/ -name '*.tfplan' -type f -delete 2>/dev/null || true
	@echo "$(GREEN)✓ Clean complete$(RESET)"
