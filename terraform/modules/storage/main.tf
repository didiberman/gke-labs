# ------------------------------------------------------------------------------
# Module: storage
# Creates:
#   1. Receipts bucket  — stores payment receipts; CORS-enabled for web uploads,
#                         tiered storage lifecycle, versioning, IAM for payments SA.
#   2. Backups bucket   — stores GKE logs / Terraform state backups; no CORS,
#                         single-tier lifecycle (delete after 90 days).
# ------------------------------------------------------------------------------

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

# ------------------------------------------------------------------------------
# Local helpers
# ------------------------------------------------------------------------------
locals {
  receipts_bucket_name = "${var.project_id}-${var.name}-receipts"
  backups_bucket_name  = "${var.project_id}-${var.name}-backups"
}

# ==============================================================================
# 1. Receipts bucket
# ==============================================================================
resource "google_storage_bucket" "receipts" {
  project  = var.project_id
  name     = local.receipts_bucket_name
  location = var.region

  # Enforce bucket-level access control (no per-object ACLs)
  uniform_bucket_level_access = true

  # Allow Terraform to destroy even if the bucket is not empty.
  # Set to false for production to prevent accidental data loss.
  force_destroy = var.force_destroy

  # --------------------------------------------------------------------------
  # Versioning — required for lifecycle num_newer_versions rule
  # --------------------------------------------------------------------------
  versioning {
    enabled = true
  }

  # --------------------------------------------------------------------------
  # Lifecycle rules
  # --------------------------------------------------------------------------
  lifecycle_rule {
    # Delete noncurrent versions once 5 newer versions exist
    action {
      type = "Delete"
    }
    condition {
      num_newer_versions = 5
      with_state         = "ARCHIVED"
    }
  }

  lifecycle_rule {
    # Move live objects to NEARLINE after 30 days (infrequent access)
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
    condition {
      age        = 30
      with_state = "LIVE"
    }
  }

  lifecycle_rule {
    # Move live objects to COLDLINE after 90 days (archive)
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
    condition {
      age        = 90
      with_state = "LIVE"
    }
  }

  # --------------------------------------------------------------------------
  # CORS — allows browser-based direct uploads from your frontend domain.
  # Adjust origins in the calling module for production.
  # --------------------------------------------------------------------------
  cors {
    origin          = var.cors_origins
    method          = ["GET", "HEAD", "PUT", "POST", "DELETE"]
    response_header = ["Content-Type", "Content-MD5", "x-goog-resumable"]
    max_age_seconds = 3600
  }

  labels = var.labels
}

# ==============================================================================
# 2. Backups bucket (GKE logs, Terraform state, etc.)
# ==============================================================================
resource "google_storage_bucket" "backups" {
  project  = var.project_id
  name     = local.backups_bucket_name
  location = var.region

  uniform_bucket_level_access = true
  force_destroy               = var.force_destroy

  versioning {
    enabled = true
  }

  lifecycle_rule {
    # Hard delete everything older than 90 days to control costs
    action {
      type = "Delete"
    }
    condition {
      age        = 90
      with_state = "ANY"
    }
  }

  labels = var.labels
}

# ==============================================================================
# 3. IAM — payments-api SA gets objectAdmin on the receipts bucket
# ==============================================================================
resource "google_storage_bucket_iam_member" "payments_api_receipts_admin" {
  bucket = google_storage_bucket.receipts.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${var.payments_api_sa_email}"
}
