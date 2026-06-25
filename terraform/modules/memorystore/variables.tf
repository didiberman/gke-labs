# ------------------------------------------------------------------------------
# Module: memorystore — variables
# ------------------------------------------------------------------------------

variable "name" {
  description = "Base name for the Redis instance. Combined with env to form the full resource name."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,38}[a-z0-9]$", var.name))
    error_message = "name must be 3-40 lowercase alphanumeric characters or hyphens, starting with a letter."
  }
}

variable "project_id" {
  description = "GCP project ID in which to create the Memorystore instance."
  type        = string
}

variable "region" {
  description = "GCP region for the Redis instance (e.g. europe-west1)."
  type        = string
  default     = "europe-west1"
}

variable "env" {
  description = "Environment label (e.g. dev, staging, prod). Appended to the instance name."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "env must be one of: dev, staging, prod."
  }
}

variable "vpc_id" {
  description = "Self-link or ID of the VPC network to which the Redis instance is attached via Private Service Access."
  type        = string
}

variable "private_ip_range_name" {
  description = "Name of the allocated IP range (google_compute_global_address) used for Private Service Access."
  type        = string
}

variable "tier" {
  description = "Service tier: BASIC (single node) or STANDARD_HA (replicated, high-availability)."
  type        = string
  default     = "BASIC"

  validation {
    condition     = contains(["BASIC", "STANDARD_HA"], var.tier)
    error_message = "tier must be BASIC or STANDARD_HA."
  }
}

variable "memory_size_gb" {
  description = "Redis memory size in GiB. Minimum 1 for BASIC, minimum 5 for STANDARD_HA."
  type        = number
  default     = 1

  validation {
    condition     = var.memory_size_gb >= 1
    error_message = "memory_size_gb must be at least 1."
  }
}

variable "location_id" {
  description = "Primary zone for the Redis instance (e.g. europe-west1-b). Defaults to -b zone in the region."
  type        = string
  default     = "europe-west1-b"
}

variable "alternative_location_id" {
  description = "Replica zone for STANDARD_HA tier (e.g. europe-west1-c). Ignored for BASIC tier."
  type        = string
  default     = "europe-west1-c"
}

variable "labels" {
  description = "Map of labels to apply to the Redis instance."
  type        = map(string)
  default     = {}
}
