#!/usr/bin/env bash
# ==============================================================================
# scripts/connect.sh
#
# Developer convenience script that:
#   1. Authenticates kubectl against the GKE dev cluster
#   2. Port-forwards Grafana    → localhost:3000  (background)
#   3. Port-forwards Temporal UI → localhost:8080  (background)
#   4. Displays a live pod summary across key namespaces
#   5. Prints a cheat-sheet of useful kubectl commands
#
# Usage:
#   ./scripts/connect.sh [PROJECT_ID] [REGION] [CLUSTER_NAME]
#
# All args are optional — defaults match the Terraform-provisioned dev cluster.
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

# ── Argument parsing ───────────────────────────────────────────────────────────
PROJECT_ID="${1:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${2:-europe-west1}"
CLUSTER_NAME="${3:-gke-labs-dev}"

# Port-forward targets
GRAFANA_LOCAL_PORT=3000
TEMPORAL_LOCAL_PORT=8080

# Namespaces to summarise
WATCH_NAMESPACES=("observability" "temporal" "payments" "default")

# ── Validate prerequisites ─────────────────────────────────────────────────────
for cmd in gcloud kubectl; do
  command -v "${cmd}" &>/dev/null || {
    echo -e "${RED}✗${NC} '${cmd}' not found in PATH." >&2
    exit 1
  }
done

[[ -z "${PROJECT_ID}" ]] && {
  echo -e "${RED}✗${NC} No project ID. Pass it as the first argument or set a gcloud default." >&2
  exit 1
}

# ── Banner ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║          GKE Labs — Connect & Port-Forward           ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Project :${NC} ${PROJECT_ID}"
echo -e "  ${BOLD}Region  :${NC} ${REGION}"
echo -e "  ${BOLD}Cluster :${NC} ${CLUSTER_NAME}"
echo ""

# ── 1. Get GKE credentials ─────────────────────────────────────────────────────
info "Fetching GKE credentials for cluster '${CLUSTER_NAME}'…"
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --project "${PROJECT_ID}"
success "kubectl context set to cluster '${CLUSTER_NAME}'."

# ── Helper: stop any existing port-forward on a given local port ───────────────
kill_port_forward() {
  local port="$1"
  local existing_pid
  existing_pid=$(lsof -ti "tcp:${port}" 2>/dev/null || true)
  if [[ -n "${existing_pid}" ]]; then
    warn "Killing existing process on port ${port} (PID: ${existing_pid})"
    kill "${existing_pid}" 2>/dev/null || true
    sleep 1
  fi
}

# ── Helper: start a port-forward in the background and store its PID ──────────
# Usage: start_port_forward <namespace> <resource> <local-port> <remote-port> <label>
start_port_forward() {
  local namespace="$1"
  local resource="$2"
  local local_port="$3"
  local remote_port="$4"
  local label="$5"

  kill_port_forward "${local_port}"

  # Check the resource exists before trying to forward
  if ! kubectl get "${resource}" -n "${namespace}" &>/dev/null 2>&1; then
    warn "${label}: resource '${resource}' not found in namespace '${namespace}'. Skipping."
    return
  fi

  kubectl port-forward "${resource}" \
    "${local_port}:${remote_port}" \
    -n "${namespace}" \
    --address 127.0.0.1 \
    &>/tmp/pf-${label// /-}.log &
  local pf_pid=$!

  # Give it a moment to establish
  sleep 2

  if kill -0 "${pf_pid}" 2>/dev/null; then
    success "${label}: port-forward running → http://localhost:${local_port}  (PID ${pf_pid})"
    echo "${pf_pid}" > "/tmp/pf-${label// /-}.pid"
  else
    warn "${label}: port-forward failed to start. Check /tmp/pf-${label// /-}.log"
  fi
}

# ── 2. Port-forward Grafana ────────────────────────────────────────────────────
info "Starting Grafana port-forward (localhost:${GRAFANA_LOCAL_PORT})…"
# kube-prometheus-stack names the service `<release>-grafana`
start_port_forward \
  "observability" \
  "svc/observability-grafana" \
  "${GRAFANA_LOCAL_PORT}" \
  "80" \
  "Grafana"

# ── 3. Port-forward Temporal UI ───────────────────────────────────────────────
info "Starting Temporal UI port-forward (localhost:${TEMPORAL_LOCAL_PORT})…"
start_port_forward \
  "temporal" \
  "svc/temporal-ui" \
  "${TEMPORAL_LOCAL_PORT}" \
  "8080" \
  "Temporal UI"

# ── 4. Pod summary ────────────────────────────────────────────────────────────
echo ""
info "Pod summary across key namespaces:"
echo ""
for ns in "${WATCH_NAMESPACES[@]}"; do
  echo -e "  ${BOLD}Namespace: ${ns}${NC}"
  if kubectl get namespace "${ns}" &>/dev/null 2>&1; then
    kubectl get pods -n "${ns}" \
      --no-headers \
      -o custom-columns='  NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,AGE:.metadata.creationTimestamp' \
      2>/dev/null | head -20 || echo "    (no pods)"
  else
    echo -e "    ${YELLOW}(namespace does not exist yet)${NC}"
  fi
  echo ""
done

# ── 5. Kubectl cheat-sheet ─────────────────────────────────────────────────────
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              Useful Commands Cheat-Sheet             ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}── Access UIs ──────────────────────────────────────────${NC}"
echo -e "  Grafana     → ${CYAN}http://localhost:${GRAFANA_LOCAL_PORT}${NC}  (admin / prom-operator)"
echo -e "  Temporal UI → ${CYAN}http://localhost:${TEMPORAL_LOCAL_PORT}${NC}"
echo ""
echo -e "${BOLD}── Observability ───────────────────────────────────────${NC}"
echo -e "  # Watch all pods in observability namespace"
echo -e "  ${CYAN}kubectl get pods -n observability -w${NC}"
echo ""
echo -e "  # Tail Grafana logs"
echo -e "  ${CYAN}kubectl logs -n observability -l app.kubernetes.io/name=grafana -f${NC}"
echo ""
echo -e "  # Tail Loki logs"
echo -e "  ${CYAN}kubectl logs -n observability -l app.kubernetes.io/name=loki -f${NC}"
echo ""
echo -e "  # Tail Tempo logs"
echo -e "  ${CYAN}kubectl logs -n observability -l app.kubernetes.io/name=tempo -f${NC}"
echo ""
echo -e "  # Check Prometheus targets"
echo -e "  ${CYAN}kubectl port-forward svc/observability-kube-prometheus-prometheus 9090:9090 -n observability${NC}"
echo -e "  # then visit http://localhost:9090/targets"
echo ""
echo -e "${BOLD}── Application (payments-api) ──────────────────────────${NC}"
echo -e "  ${CYAN}kubectl get pods -n payments -w${NC}"
echo -e "  ${CYAN}kubectl logs -n payments -l app=payments-api -f --tail=100${NC}"
echo -e "  ${CYAN}kubectl describe pod -n payments -l app=payments-api${NC}"
echo ""
echo -e "${BOLD}── Temporal ─────────────────────────────────────────────${NC}"
echo -e "  ${CYAN}kubectl get pods -n temporal -w${NC}"
echo -e "  ${CYAN}kubectl logs -n temporal -l app.kubernetes.io/name=temporal -f${NC}"
echo ""
echo -e "${BOLD}── Resource Usage ──────────────────────────────────────${NC}"
echo -e "  ${CYAN}kubectl top nodes${NC}"
echo -e "  ${CYAN}kubectl top pods -A${NC}"
echo ""
echo -e "${BOLD}── Cluster Info ────────────────────────────────────────${NC}"
echo -e "  ${CYAN}kubectl cluster-info${NC}"
echo -e "  ${CYAN}kubectl get nodes -o wide${NC}"
echo -e "  ${CYAN}kubectl get events -A --sort-by=.metadata.creationTimestamp | tail -30${NC}"
echo ""
echo -e "${BOLD}── Port-Forward Management ─────────────────────────────${NC}"
echo -e "  # Kill all background port-forwards started by this script:"
echo -e "  ${CYAN}kill \$(cat /tmp/pf-Grafana.pid /tmp/pf-Temporal-UI.pid 2>/dev/null) 2>/dev/null || true${NC}"
echo ""
echo -e "${BOLD}── Helm ────────────────────────────────────────────────${NC}"
echo -e "  ${CYAN}helm list -A${NC}"
echo -e "  ${CYAN}helm status observability -n observability${NC}"
echo -e "  ${CYAN}helm history observability -n observability${NC}"
echo ""
