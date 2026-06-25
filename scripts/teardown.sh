#!/usr/bin/env bash
# ==============================================================================
# scripts/teardown.sh
#
# Safe teardown of the gke-labs infrastructure.
#
# What it does:
#   1. Warns the operator with a 10-second countdown (Ctrl-C to abort)
#   2. Runs `terraform destroy` in the dev environment directory
#   3. Verifies that GKE clusters, Cloud SQL instances, and Redis instances
#      have all been deleted from the project
#   4. Prints a cost-reminder and optional GCS bucket cleanup instructions
#
# Usage:
#   ./scripts/teardown.sh [PROJECT_ID] [REGION]
#
# Prerequisites:
#   - Terraform installed and authenticated
#   - gcloud CLI authenticated with appropriate IAM roles
# ==============================================================================
set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}==>${NC} ${BOLD}$*${NC}"; }
success() { echo -e "${GREEN}✓${NC}  $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
fatal()   { echo -e "${RED}✗${NC}  $*" >&2; exit 1; }

# ── Argument parsing ───────────────────────────────────────────────────────────
PROJECT_ID="${1:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${2:-europe-west1}"

[[ -z "${PROJECT_ID}" ]] && fatal "No project ID supplied and no gcloud default project configured."

# Resolve the repo root (one level up from the scripts directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/environments/dev"

# ── Warning banner ─────────────────────────────────────────────────────────────
echo ""
echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}║  ⚠   DESTRUCTIVE OPERATION — READ CAREFULLY   ⚠         ║${NC}"
echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  This script will ${RED}${BOLD}DESTROY${NC} all infrastructure in:"
echo ""
echo -e "    ${BOLD}Project :${NC} ${PROJECT_ID}"
echo -e "    ${BOLD}Region  :${NC} ${REGION}"
echo -e "    ${BOLD}TF dir  :${NC} ${TF_DIR}"
echo ""
warn "All GKE clusters, Cloud SQL databases, Redis instances, and associated"
warn "storage will be PERMANENTLY DELETED. This cannot be undone."
echo ""

# ── 10-second countdown ────────────────────────────────────────────────────────
echo -e "${YELLOW}Press Ctrl-C now to abort. Proceeding in:${NC}"
for i in {10..1}; do
  printf "  %2d seconds...\r" "${i}"
  sleep 1
done
echo ""
echo ""

# ── Pre-flight checks ──────────────────────────────────────────────────────────
info "Running pre-flight checks…"

[[ -d "${TF_DIR}" ]] || fatal "Terraform directory not found: ${TF_DIR}"
command -v terraform &>/dev/null || fatal "'terraform' CLI not found in PATH."
command -v gcloud    &>/dev/null || fatal "'gcloud' CLI not found in PATH."

# Verify Terraform is initialised
if [[ ! -d "${TF_DIR}/.terraform" ]]; then
  warn "Terraform not initialised in ${TF_DIR}. Running terraform init…"
  (cd "${TF_DIR}" && terraform init -reconfigure)
fi

success "Pre-flight checks passed."

# ── Terraform destroy ──────────────────────────────────────────────────────────
info "Running terraform destroy in ${TF_DIR}…"
(
  cd "${TF_DIR}"
  terraform destroy \
    -var="project_id=${PROJECT_ID}" \
    -var="region=${REGION}" \
    -auto-approve \
    -parallelism=10
)
success "terraform destroy completed."

# ── Verify GKE clusters ────────────────────────────────────────────────────────
info "Verifying GKE clusters are gone…"
GKE_CLUSTERS=$(
  gcloud container clusters list \
    --project="${PROJECT_ID}" \
    --filter="zone~${REGION}" \
    --format="value(name)" 2>/dev/null || true
)

if [[ -n "${GKE_CLUSTERS}" ]]; then
  warn "The following GKE clusters still exist (may still be deleting):"
  echo "${GKE_CLUSTERS}" | while read -r c; do echo "    - ${c}"; done
else
  success "No GKE clusters found in project/region — clean."
fi

# ── Verify Cloud SQL instances ─────────────────────────────────────────────────
info "Verifying Cloud SQL instances are gone…"
SQL_INSTANCES=$(
  gcloud sql instances list \
    --project="${PROJECT_ID}" \
    --format="value(name)" 2>/dev/null || true
)

if [[ -n "${SQL_INSTANCES}" ]]; then
  warn "The following Cloud SQL instances still exist:"
  echo "${SQL_INSTANCES}" | while read -r s; do echo "    - ${s}"; done
else
  success "No Cloud SQL instances found — clean."
fi

# ── Verify Redis (Memorystore) instances ───────────────────────────────────────
info "Verifying Redis (Memorystore) instances are gone…"
REDIS_INSTANCES=$(
  gcloud redis instances list \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --format="value(name)" 2>/dev/null || true
)

if [[ -n "${REDIS_INSTANCES}" ]]; then
  warn "The following Redis instances still exist:"
  echo "${REDIS_INSTANCES}" | while read -r r; do echo "    - ${r}"; done
else
  success "No Redis instances found — clean."
fi

# ── Cost reminder ──────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ✓  Teardown complete!${NC}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}Cost Reminder:${NC}"
echo ""
echo -e "  • GKE nodes bill by the minute — verify cluster deletion in the"
echo -e "    GCP console: https://console.cloud.google.com/kubernetes/list"
echo ""
echo -e "  • Cloud SQL and Redis instances bill until DELETED (not stopped)."
echo -e "    Verify at: https://console.cloud.google.com/sql/instances"
echo -e "               https://console.cloud.google.com/memorystore/redis/instances"
echo ""
echo -e "  • PersistentVolumeClaims map to GCP Persistent Disks that"
echo -e "    continue to bill after the cluster is gone."
echo -e "    Check: https://console.cloud.google.com/compute/disks"
echo ""
echo -e "  • The Terraform state bucket (${PROJECT_ID}-terraform-state) is"
echo -e "    NOT deleted by this script (intentional — preserves state history)."
echo -e "    To remove it manually:"
echo -e "    ${CYAN}gsutil rm -r gs://${PROJECT_ID}-terraform-state${NC}"
echo ""
echo -e "  • Check for lingering costs any time at:"
echo -e "    https://console.cloud.google.com/billing"
echo ""
