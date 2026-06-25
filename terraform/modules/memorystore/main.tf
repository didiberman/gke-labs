# ------------------------------------------------------------------------------
# Module: memorystore
# Creates a Google Cloud Memorystore (Redis) instance with:
#   - Private Service Access connectivity
#   - Auth and in-transit encryption (TLS)
#   - Configurable tier (BASIC for dev, STANDARD_HA for prod)
#   - Weekly maintenance window on Sunday at 03:00
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
  # Only STANDARD_HA tier supports a replica zone; guard against setting
  # alternative_location_id on BASIC instances which would cause an API error.
  is_ha = var.tier == "STANDARD_HA"
}

# ------------------------------------------------------------------------------
# Redis Instance
# ------------------------------------------------------------------------------
resource "google_redis_instance" "this" {
  project = var.project_id
  name    = "${var.name}-redis-${var.env}"

  # --------------------------------------------------------------------------
  # Capacity & tier
  # --------------------------------------------------------------------------
  tier           = var.tier
  memory_size_gb = var.memory_size_gb

  # --------------------------------------------------------------------------
  # Location
  # Primary zone is always set; alternative_location_id only for STANDARD_HA
  # to avoid API validation errors on BASIC instances.
  # --------------------------------------------------------------------------
  region                  = var.region
  location_id             = var.location_id
  alternative_location_id = local.is_ha ? var.alternative_location_id : null

  # --------------------------------------------------------------------------
  # Networking — Private Service Access
  # The VPC must already have a private service connection configured via
  # google_service_networking_connection before this resource is created.
  # --------------------------------------------------------------------------
  connect_mode       = "PRIVATE_SERVICE_ACCESS"
  authorized_network = var.vpc_id
  reserved_ip_range  = var.private_ip_range_name

  # --------------------------------------------------------------------------
  # Redis version
  # --------------------------------------------------------------------------
  redis_version = "REDIS_7_0"

  # --------------------------------------------------------------------------
  # Security — Auth token + TLS
  # auth_enabled=true provisions an AUTH token (exposed via output).
  # SERVER_AUTHENTICATION enforces TLS from clients to Redis.
  # --------------------------------------------------------------------------
  auth_enabled            = true
  transit_encryption_mode = "SERVER_AUTHENTICATION"

  # --------------------------------------------------------------------------
  # Maintenance policy — weekly, Sunday 03:00 UTC
  # --------------------------------------------------------------------------
  maintenance_policy {
    weekly_maintenance_window {
      day = "SUNDAY"
      start_time {
        hours   = 3
        minutes = 0
        seconds = 0
        nanos   = 0
      }
    }
  }

  # --------------------------------------------------------------------------
  # Labels
  # --------------------------------------------------------------------------
  labels = var.labels
}
