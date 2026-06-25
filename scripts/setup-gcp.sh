#!/usr/bin/env bash
# ==============================================================================
# scripts/setup-gcp.sh
#
# One-shot bootstrap script that prepares a GCP project for the gke-labs
# Terraform workspace:
#   1. Enables all required GCP APIs
#   2. Creates the Terraform remote-state GCS bucket (if it doesn't exist)
#   3. Prints next-step instructions
#
# Usage:
#   ./scripts/setup-gcp.sh [PROJECT_ID] [REGION]
#
# Examples:
#   ./scripts/setup-gcp.sh                          # uses gcloud default project + europe-west1
#   ./scripts/setup-gcp.sh gke-labs europe-west1
#
# Prerequisites:
#   - gcloud CLI authenticated with an account that has Project Editor / Owner
#   - The project must already exist in GCP
# ==============================================================================
set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

info()    { echo -e "${CYAN}==>${NC} ${BOLD}$*${NC}"; }
success() { echo -e "${GREEN}✓${NC}  $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
fatal()   { echo -e "${RED}✗${NC}  $*" >&2; exit 1; }

# ── Argument parsing ───────────────────────────────────────────────────────────
PROJECT_ID="${1:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${2:-europe-west1}"

[[ -z "${PROJECT_ID}" ]] && fatal "No project ID supplied and no gcloud default project configured."

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║          GKE Labs — GCP Bootstrap Script             ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
info "Project : ${PROJECT_ID}"
info "Region  : ${REGION}"
echo ""

# ── Verify the project is accessible ──────────────────────────────────────────
info "Verifying project access…"
if ! gcloud projects describe "${PROJECT_ID}" --quiet &>/dev/null; then
  fatal "Project '${PROJECT_ID}' not found or you lack access. Check your credentials and project ID."
fi
success "Project '${PROJECT_ID}' is accessible."

# ── Set gcloud default project for subsequent commands ────────────────────────
gcloud config set project "${PROJECT_ID}" --quiet

# ── Enable required GCP APIs ───────────────────────────────────────────────────
info "Enabling required GCP APIs (this may take 1–2 minutes)…"

APIS=(
  # Core GKE infrastructure
  container.googleapis.com              # Google Kubernetes Engine
  compute.googleapis.com               # Compute Engine (node VMs, VPCs)

  # Data services
  sqladmin.googleapis.com              # Cloud SQL (PostgreSQL for payments-api)
  redis.googleapis.com                 # Memorystore (Redis for caching)

  # Storage & secret management
  storage.googleapis.com               # Cloud Storage (Terraform state, Loki prod)
  secretmanager.googleapis.com         # Secret Manager (DB passwords, API keys)

  # Networking
  servicenetworking.googleapis.com     # Private Service Connect (Cloud SQL private IP)

  # IAM & resource management
  cloudresourcemanager.googleapis.com  # Needed by Terraform to manage IAM bindings
  iam.googleapis.com                   # IAM (service accounts, Workload Identity)

  # Container registry
  artifactregistry.googleapis.com      # Artifact Registry (Docker images)

  # Observability
  monitoring.googleapis.com            # Cloud Monitoring (metrics sink)
  logging.googleapis.com               # Cloud Logging  (log sink)
  cloudtrace.googleapis.com            # Cloud Trace    (distributed tracing)
)

gcloud services enable "${APIS[@]}" --project "${PROJECT_ID}"

success "All required APIs enabled."

# ── Create Terraform remote-state GCS bucket ───────────────────────────────────
BUCKET_NAME="${PROJECT_ID}-terraform-state"
info "Checking Terraform state bucket: gs://${BUCKET_NAME}"

if gsutil ls "gs://${BUCKET_NAME}" &>/dev/null; then
  success "Bucket already exists: gs://${BUCKET_NAME}"
else
  info "Creating bucket gs://${BUCKET_NAME} in region ${REGION}…"
  gsutil mb \
    -p "${PROJECT_ID}" \
    -l "${REGION}" \
    -b on \
    "gs://${BUCKET_NAME}"

  # Versioning lets you recover from accidental state file deletions
  gsutil versioning set on "gs://${BUCKET_NAME}"

  # Uniform bucket-level access — simpler IAM, no per-object ACLs
  gsutil ubla set on "gs://${BUCKET_NAME}"

  success "Bucket created and versioning/UBLA enabled: gs://${BUCKET_NAME}"
fi

# ── Verify Artifact Registry repository (optional, idempotent) ─────────────────
AR_REPO="gke-labs"
AR_LOCATION="${REGION}"
info "Checking Artifact Registry repository '${AR_REPO}'…"

if gcloud artifacts repositories describe "${AR_REPO}" \
    --location="${AR_LOCATION}" \
    --project="${PROJECT_ID}" \
    --quiet &>/dev/null; then
  success "Artifact Registry repo '${AR_REPO}' already exists."
else
  info "Creating Artifact Registry Docker repository '${AR_REPO}' in ${AR_LOCATION}…"
  gcloud artifacts repositories create "${AR_REPO}" \
    --repository-format=docker \
    --location="${AR_LOCATION}" \
    --description="GKE Labs Docker image repository" \
    --project="${PROJECT_ID}" \
    --quiet
  success "Artifact Registry repo '${AR_REPO}' created."
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ✓  GCP Bootstrap complete!${NC}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Project ID  :${NC} ${PROJECT_ID}"
echo -e "  ${BOLD}Region      :${NC} ${REGION}"
echo -e "  ${BOLD}State Bucket:${NC} gs://${BUCKET_NAME}"
echo -e "  ${BOLD}AR Repo     :${NC} ${AR_LOCATION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo ""
echo -e "  1. Initialise Terraform:"
echo -e "     ${CYAN}cd terraform/environments/dev${NC}"
echo -e "     ${CYAN}cp terraform.tfvars.example terraform.tfvars${NC}"
echo -e "     # Edit terraform.tfvars — set project_id = \"${PROJECT_ID}\""
echo ""
echo -e "  2. Deploy infrastructure:"
echo -e "     ${CYAN}terraform init${NC}"
echo -e "     ${CYAN}terraform plan -out=tfplan${NC}"
echo -e "     ${CYAN}terraform apply tfplan${NC}"
echo ""
echo -e "  3. Connect to the cluster:"
echo -e "     ${CYAN}./scripts/connect.sh${NC}"
echo ""
