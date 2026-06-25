# =============================================================================
# Cloud SQL — PostgreSQL 15 Module — variables.tf
# =============================================================================

# ---------------------------------------------------------------------------
# Core Identity
# ---------------------------------------------------------------------------

variable "name" {
  description = "Base name for the Cloud SQL instance. Combined with 'env' to form the instance name (e.g. 'gke-lab-postgres-dev')."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,88}$", var.name))
    error_message = "Instance name must start with a lowercase letter and contain only lowercase letters, digits, and hyphens."
  }
}

variable "project_id" {
  description = "GCP project ID in which the Cloud SQL instance is created."
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "project_id must not be empty."
  }
}

variable "env" {
  description = "Deployment environment (dev, staging, prod). Appended to the instance name and applied as a user label."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "env must be one of: dev, staging, prod."
  }
}

variable "region" {
  description = "GCP region where the Cloud SQL instance is created. Should match (or be close to) the GKE cluster region to minimise latency."
  type        = string
  default     = "europe-west1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a valid GCP region identifier (e.g. europe-west1)."
  }
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "vpc_id" {
  description = "Self-link of the VPC network used for the Cloud SQL private IP allocation (e.g. projects/{project}/global/networks/{network})."
  type        = string
}

variable "private_ip_range_name" {
  description = "Name of the allocated IP range (created via google_compute_global_address + google_service_networking_connection) used for Cloud SQL private IP assignment."
  type        = string
}

# ---------------------------------------------------------------------------
# Instance Sizing
# ---------------------------------------------------------------------------

variable "tier" {
  description = "Cloud SQL machine tier. Use db-g1-small for dev (low cost), db-n1-standard-2 or higher for production."
  type        = string
  default     = "db-g1-small"

  validation {
    condition     = can(regex("^db-", var.tier))
    error_message = "tier must be a valid Cloud SQL machine type starting with 'db-' (e.g. db-g1-small, db-n1-standard-2)."
  }
}

variable "availability_type" {
  description = "Cloud SQL availability type. ZONAL for dev (cheaper, no HA), REGIONAL for staging/prod (automatic failover to secondary zone)."
  type        = string
  default     = "ZONAL"

  validation {
    condition     = contains(["ZONAL", "REGIONAL"], var.availability_type)
    error_message = "availability_type must be either ZONAL or REGIONAL."
  }
}

# ---------------------------------------------------------------------------
# Database Credentials (Sensitive)
# ---------------------------------------------------------------------------

variable "db_password" {
  description = "Password for the 'payments-api' database user. Mark as sensitive. In production, generate with random_password and store in Secret Manager."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.db_password) >= 16
    error_message = "db_password must be at least 16 characters long."
  }
}

variable "temporal_db_password" {
  description = "Password for the 'temporal' database user. Mark as sensitive. In production, generate with random_password and store in Secret Manager."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.temporal_db_password) >= 16
    error_message = "temporal_db_password must be at least 16 characters long."
  }
}

# ---------------------------------------------------------------------------
# Safety
# ---------------------------------------------------------------------------

variable "deletion_protection" {
  description = "Whether to enable Cloud SQL deletion protection. Set to false for lab/dev so `terraform destroy` works. MUST be true for production."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Labels
# ---------------------------------------------------------------------------

variable "labels" {
  description = "Map of GCP resource labels applied to the Cloud SQL instance. Merged with module-generated labels (env, managed=terraform)."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for k, v in var.labels :
      can(regex("^[a-z][a-z0-9_-]{0,62}$", k)) && can(regex("^[a-z0-9_-]{0,63}$", v))
    ])
    error_message = "Label keys must start with a lowercase letter and contain only lowercase letters, digits, underscores, and hyphens. Values must contain only lowercase letters, digits, underscores, and hyphens (max 63 chars each)."
  }
}
