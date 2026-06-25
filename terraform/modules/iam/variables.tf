# =============================================================================
# modules/iam/variables.tf
# =============================================================================

variable "name" {
  description = "Prefix applied to every resource created by this module (e.g. 'gke-labs'). Must be lowercase, letters and hyphens only."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.name))
    error_message = "name must start with a lowercase letter, contain only lowercase letters, numbers, and hyphens, and be 2–21 characters long."
  }
}

variable "project_id" {
  description = "GCP project ID where IAM resources will be created."
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "project_id must be a non-empty string."
  }
}

variable "region" {
  description = "GCP region for the Artifact Registry repository."
  type        = string
  default     = "europe-west1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a valid GCP region (e.g. europe-west1)."
  }
}

variable "labels" {
  description = "Map of labels to apply to all resources that support labels."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for k, v in var.labels :
      can(regex("^[a-z][a-z0-9_-]{0,62}$", k)) && can(regex("^[a-z0-9_-]{0,63}$", v))
    ])
    error_message = "Label keys must start with a lowercase letter and contain only lowercase letters, numbers, underscores, or hyphens (max 63 chars). Label values may contain lowercase letters, numbers, underscores, or hyphens (max 63 chars)."
  }
}

variable "payments_storage_bucket" {
  description = "Name of the GCS bucket the payments-api service account needs objectAdmin on. Scopes the storage permission to a single bucket instead of project-wide."
  type        = string
  default     = "" # if empty, no bucket-level binding is created; project-level storage.objectAdmin is used as fallback
}
