# ------------------------------------------------------------------------------
# Module: secret-manager
# Creates Secret Manager secrets for the payments-api service:
#   - payments-api-db-password   (Cloud SQL password)
#   - payments-api-redis-auth    (Redis AUTH token)
#   - payments-api-jwt-secret    (JWT signing secret)
#
# Each secret:
#   • Uses automatic replication (simplest for single-region labs; swap to
#     user-managed replication for multi-region prod workloads)
#   • Has a versioned secret_data payload
#   • Grants roles/secretmanager.secretAccessor to the payments-api SA
# ------------------------------------------------------------------------------

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}

# ------------------------------------------------------------------------------
# JWT secret fallback — generated automatically when var.jwt_secret is empty.
# The result is a cryptographically random 64-byte hex string (128 hex chars).
# This resource is only used when var.jwt_secret == ""; callers can override it
# by providing their own secret (e.g. from a KMS-managed value).
# ------------------------------------------------------------------------------
resource "random_password" "jwt_secret" {
  length  = 64
  special = false # hex-safe: alphanumeric only, suitable for JWT HS256/HS512
}

# ------------------------------------------------------------------------------
# Local map — maps logical secret names to their sensitive values.
# Falls back to the generated random password when jwt_secret is not supplied.
# Using a local rather than inline for_each makes the structure readable and
# easy to extend without touching resource blocks.
# ------------------------------------------------------------------------------
locals {
  effective_jwt_secret = var.jwt_secret != "" ? var.jwt_secret : random_password.jwt_secret.result

  secrets = {
    "payments-api-db-password" = var.db_password
    "payments-api-redis-auth"  = var.redis_auth_string
    "payments-api-jwt-secret"  = local.effective_jwt_secret
  }
}

# ------------------------------------------------------------------------------
# Secret containers
# for_each iterates over the local map; the key becomes part of the resource
# address (e.g. google_secret_manager_secret.this["payments-api-db-password"])
# ------------------------------------------------------------------------------
resource "google_secret_manager_secret" "this" {
  for_each = local.secrets

  project   = var.project_id
  secret_id = each.key

  # Automatic replication — GCP manages replica placement.
  # For production, consider `user_managed` replication with explicit regions.
  replication {
    auto {}
  }

  labels = merge(var.labels, {
    managed-by = "terraform"
    module     = "secret-manager"
  })
}

# ------------------------------------------------------------------------------
# Secret versions — stores the actual plaintext value (encrypted at rest by
# Secret Manager). Sensitive values never appear in Terraform state in plaintext.
# ------------------------------------------------------------------------------
resource "google_secret_manager_secret_version" "this" {
  for_each = local.secrets

  secret      = google_secret_manager_secret.this[each.key].id
  secret_data = each.value

  # Prevent Terraform from destroying the current version on update.
  # Secret Manager versions are immutable; adding new data creates a new version.
  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------------------------
# IAM — grants the accessor SA read access to every secret in this module.
# Using a separate for_each resource keeps IAM bindings atomic and auditable.
# ------------------------------------------------------------------------------
resource "google_secret_manager_secret_iam_member" "accessor" {
  for_each = local.secrets

  project   = var.project_id
  secret_id = google_secret_manager_secret.this[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.accessor_sa_email}"
}
