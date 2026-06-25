# =============================================================================
# GKE Standard Cluster Module — variables.tf
# =============================================================================

# ---------------------------------------------------------------------------
# Core Identity
# ---------------------------------------------------------------------------

variable "name" {
  description = "Base name for the GKE cluster and associated node pools. Combined with 'env' to form the cluster name (e.g. 'gke-lab-dev')."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,38}[a-z0-9]$", var.name))
    error_message = "Cluster name must be 3–40 characters, start with a lowercase letter, and contain only lowercase letters, digits, and hyphens."
  }
}

variable "project_id" {
  description = "GCP project ID in which the GKE cluster and node pools are created."
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "project_id must not be empty."
  }
}

variable "env" {
  description = "Deployment environment (e.g. dev, staging, prod). Appended to the cluster name and applied as a node label."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "env must be one of: dev, staging, prod."
  }
}

# ---------------------------------------------------------------------------
# Region
# ---------------------------------------------------------------------------

variable "region" {
  description = "GCP region where the regional GKE cluster is created. Regional clusters spread nodes across multiple zones for high availability."
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

variable "vpc_name" {
  description = "Self-link or name of the VPC network to attach the cluster to."
  type        = string
}

variable "subnet_name" {
  description = "Name of the subnetwork within the VPC for the cluster nodes."
  type        = string
}

variable "pods_range_name" {
  description = "Name of the secondary IP range within the subnet used for Pod IPs (VPC-native / alias IP mode)."
  type        = string
}

variable "services_range_name" {
  description = "Name of the secondary IP range within the subnet used for ClusterIP Service IPs (VPC-native / alias IP mode)."
  type        = string
}

variable "master_ipv4_cidr_block" {
  description = "CIDR block for the GKE control plane's internal IP range. Must be /28 and must not overlap with any other ranges in the VPC."
  type        = string
  default     = "172.16.0.0/28"

  validation {
    condition     = can(cidrnetmask(var.master_ipv4_cidr_block)) && tonumber(split("/", var.master_ipv4_cidr_block)[1]) == 28
    error_message = "master_ipv4_cidr_block must be a valid /28 CIDR block (e.g. 172.16.0.0/28)."
  }
}

variable "master_authorized_cidr" {
  description = "CIDR block allowed to reach the GKE control plane public endpoint. Defaults to 0.0.0.0/0 for lab convenience — restrict this in production."
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrnetmask(var.master_authorized_cidr))
    error_message = "master_authorized_cidr must be a valid CIDR block."
  }
}

# ---------------------------------------------------------------------------
# Node Identity
# ---------------------------------------------------------------------------

variable "node_sa_email" {
  description = "Email address of the GCP Service Account assigned to GKE nodes. Should have minimal permissions (e.g. roles/logging.logWriter, roles/monitoring.metricWriter, roles/artifactregistry.reader)."
  type        = string

  validation {
    condition     = can(regex("^.+@.+\\.iam\\.gserviceaccount\\.com$", var.node_sa_email))
    error_message = "node_sa_email must be a valid GCP service account email (e.g. sa-name@project-id.iam.gserviceaccount.com)."
  }
}

# ---------------------------------------------------------------------------
# Labels
# ---------------------------------------------------------------------------

variable "labels" {
  description = "Map of GCP resource labels applied to the cluster and node pools. Merged with module-generated labels (env, managed=terraform)."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for k, v in var.labels :
      can(regex("^[a-z][a-z0-9_-]{0,62}$", k)) && can(regex("^[a-z0-9_-]{0,63}$", v))
    ])
    error_message = "Label keys must start with a lowercase letter and contain only lowercase letters, digits, underscores, and hyphens (max 63 chars). Label values must contain only lowercase letters, digits, underscores, and hyphens (max 63 chars)."
  }
}
