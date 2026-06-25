# ------------------------------------------------------------------------------
# Module: secret-manager — variables
# All secret value inputs are marked sensitive so Terraform redacts them in
# plan/apply output and never writes them in clear text to the console.
# ------------------------------------------------------------------------------

variable "name" {
  description = "Logical name for this secret group (e.g. 'payments-api'). Used for labelling."
  type        = string
}

variable "project_id" {
  description = "GCP project ID in which Secret Manager secrets will be created."
  type        = string
}

variable "accessor_sa_email" {
  description = "Email address of the GCP service account that will be granted roles/secretmanager.secretAccessor on every secret in this module (e.g. the payments-api Workload Identity SA)."
  type        = string
}

# ------------------------------------------------------------------------------
# Secret values — all sensitive
# ------------------------------------------------------------------------------

variable "db_password" {
  description = "Cloud SQL database password for the payments-api. Stored as 'payments-api-db-password'."
  type        = string
  sensitive   = true
}

variable "redis_auth_string" {
  description = "Redis AUTH token output from the Memorystore module. Stored as 'payments-api-redis-auth'."
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "JWT signing secret for the payments-api. If not provided, a random 64-character hex string is generated. Stored as 'payments-api-jwt-secret'."
  type        = string
  sensitive   = true
  default     = ""
  # The main.tf uses a random_password resource when this is empty-string.
  # See main.tf for implementation.
}

variable "labels" {
  description = "Map of GCP labels to apply to all Secret Manager resources."
  type        = map(string)
  default     = {}
}
