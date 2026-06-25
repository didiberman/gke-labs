# =============================================================================
# modules/iam/main.tf
#
# Provisions IAM primitives for the GKE lab:
#   1. GKE node pool service account  — least-privilege permissions for nodes
#   2. payments-api workload SA        — fine-grained access to Cloud SQL,
#                                        Redis, GCS, and Secret Manager
#   3. Workload Identity binding       — lets the K8s SA in namespace/payments
#                                        impersonate the GCP SA without keys
#   4. Artifact Registry repository   — Docker registry for workload images
# =============================================================================

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0, < 6.0"
    }
  }
}

# ---------------------------------------------------------------------------
# 1. GKE Node Pool Service Account
#
# Nodes run as this SA. Roles follow the principle of least privilege:
#   • logWriter                  — write Cloud Logging entries
#   • metricWriter               — push metrics to Cloud Monitoring
#   • monitoring.viewer          — allow node-local monitoring collectors to
#                                  read monitoring data (required by GKE metering)
#   • stackdriver.resourceMetadata.writer — write resource metadata descriptors
#   • artifactregistry.reader   — pull images from Artifact Registry
# ---------------------------------------------------------------------------
resource "google_service_account" "gke_nodes" {
  project      = var.project_id
  account_id   = "${var.name}-gke-nodes"
  display_name = "${var.name} GKE Node Pool SA"
  description  = "Least-privilege SA used by GKE node VMs — managed by Terraform"
}

locals {
  # Roles attached at the project level for the node SA
  gke_node_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ]
}

resource "google_project_iam_member" "gke_node_roles" {
  for_each = toset(local.gke_node_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# ---------------------------------------------------------------------------
# 2. payments-api Workload Service Account
#
# Used exclusively by the payments-api microservice. Roles:
#   • cloudsql.client       — connect to Cloud SQL instances via Cloud SQL Auth Proxy
#   • redis.viewer          — read Memorystore Redis metadata (connection info)
#   • secretmanager.secretAccessor — read application secrets (API keys, DB passwords)
#
# Storage is handled below (bucket-scoped when a bucket name is provided,
# otherwise project-wide as a fallback).
# ---------------------------------------------------------------------------
resource "google_service_account" "payments_api" {
  project      = var.project_id
  account_id   = "${var.name}-payments-api"
  display_name = "${var.name} payments-api Workload SA"
  description  = "Workload Identity SA for the payments-api microservice — managed by Terraform"
}

locals {
  # Project-level roles for the payments-api SA
  payments_api_project_roles = [
    "roles/cloudsql.client",
    "roles/redis.viewer",
    "roles/secretmanager.secretAccessor",
  ]
}

resource "google_project_iam_member" "payments_api_project_roles" {
  for_each = toset(local.payments_api_project_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.payments_api.email}"
}

# ---------------------------------------------------------------------------
# 2a. GCS storage.objectAdmin — bucket-scoped (preferred) or project-scoped
#
# When var.payments_storage_bucket is set, we grant objectAdmin on that
# specific bucket only, which is far safer than project-wide storage admin.
# If no bucket is provided we fall back to a project-level binding so the
# module stays functional even before a bucket is created.
# ---------------------------------------------------------------------------
resource "google_storage_bucket_iam_member" "payments_api_storage_bucket" {
  count = var.payments_storage_bucket != "" ? 1 : 0

  bucket = var.payments_storage_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.payments_api.email}"
}

# Fallback: project-level storage.objectAdmin when no bucket is specified.
# In production, always provide a bucket name to limit blast radius.
resource "google_project_iam_member" "payments_api_storage_project" {
  count = var.payments_storage_bucket == "" ? 1 : 0

  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.payments_api.email}"
}

# ---------------------------------------------------------------------------
# 3. Workload Identity Binding
#
# Kubernetes pods in namespace "payments" using the ServiceAccount "payments-api"
# can impersonate the GCP SA without mounting any key file.
#
# This works by annotating the K8s SA with:
#   iam.gke.io/gcp-service-account: <gcp_sa_email>
# and granting the K8s SA identity the workloadIdentityUser role on the GCP SA.
#
# The K8s SA is referenced as:
#   serviceAccount:<project>.svc.id.goog[<namespace>/<sa-name>]
# ---------------------------------------------------------------------------
# NOTE: The Workload Identity IAM binding for payments_api is intentionally
# created in the root module (main.tf) after the GKE cluster is provisioned,
# because the Workload Identity Pool (*.svc.id.goog) only exists once GKE is up.

# ---------------------------------------------------------------------------
# 4. Artifact Registry — Docker repository
#
# Stores all container images for the lab. GKE nodes pull images using the
# gke_nodes SA (artifactregistry.reader role granted above).
# Developers push images via Cloud Build or their local Docker daemon
# (requires separate developer IAM grants outside this module).
# ---------------------------------------------------------------------------
resource "google_artifact_registry_repository" "registry" {
  project       = var.project_id
  location      = var.region
  repository_id = "${var.name}-registry"
  format        = "DOCKER"
  description   = "Docker image registry for ${var.name} — managed by Terraform"

  labels = var.labels

  # Cleanup policies keep the registry lean.
  # Keep the 10 most recent tagged versions; delete untagged blobs after 14 days.
  cleanup_policies {
    id     = "keep-10-tagged"
    action = "KEEP"

    most_recent_versions {
      keep_count = 10
    }
  }

  cleanup_policies {
    id     = "delete-untagged-14d"
    action = "DELETE"

    condition {
      tag_state  = "UNTAGGED"
      older_than = "1209600s" # 14 days
    }
  }
}
