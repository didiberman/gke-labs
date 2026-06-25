# ------------------------------------------------------------------------------
# Module: storage — variables
# ------------------------------------------------------------------------------

variable "name" {
  description = "Base name component for bucket names (e.g. 'payments'). Combined with project_id to ensure global uniqueness."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,28}[a-z0-9]$", var.name))
    error_message = "name must be 3-30 lowercase alphanumeric characters or hyphens."
  }
}

variable "project_id" {
  description = "GCP project ID. Used as a prefix in bucket names to ensure global uniqueness."
  type        = string
}

variable "region" {
  description = "GCS multi-region or region for the buckets (e.g. europe-west1 or EU)."
  type        = string
  default     = "europe-west1"
}

variable "payments_api_sa_email" {
  description = "Email of the payments-api Kubernetes Workload Identity service account that receives objectAdmin on the receipts bucket."
  type        = string
}

variable "force_destroy" {
  description = "If true, Terraform can destroy non-empty buckets. Set to false for production environments."
  type        = bool
  default     = true
}

variable "cors_origins" {
  description = "List of origins to allow in CORS headers on the receipts bucket. Use ['*'] for lab, restrict for production."
  type        = list(string)
  default     = ["*"]
}

variable "labels" {
  description = "Map of GCP labels to apply to all storage resources."
  type        = map(string)
  default     = {}
}
