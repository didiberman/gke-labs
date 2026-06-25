# =============================================================================
# Cloud SQL — PostgreSQL 15 Module — main.tf
# =============================================================================
#
# Provisions a Cloud SQL PostgreSQL 15 instance with:
#   • Private IP only (no public IP) — traffic stays inside VPC
#   • Automated daily backups with PITR (point-in-time recovery)
#   • Query Insights for performance analysis
#   • Three databases: payments, temporal, temporal_visibility
#   • Two users: payments-api, temporal
#
# NOTE: Cloud SQL Private IP requires the Service Networking API to be enabled
# and a private connection to be established in the VPC before apply.
# See: scripts/setup-gcp.sh for the prerequisite setup steps.
#
# =============================================================================

# ---------------------------------------------------------------------------
# Cloud SQL Instance
# ---------------------------------------------------------------------------

resource "google_sql_database_instance" "main" {
  provider = google

  name             = "${var.name}-postgres-${var.env}"
  project          = var.project_id
  region           = var.region
  database_version = "POSTGRES_15"

  # ---------------------------------------------------------------------------
  # deletion_protection=false for lab environments so `terraform destroy` works.
  # Set to true (or override in prod tfvars) for production to prevent accidental
  # deletion of the instance and all its databases.
  # ---------------------------------------------------------------------------
  deletion_protection = var.deletion_protection

  settings {
    # Machine tier — db-g1-small is the lowest cost option suitable for dev/test.
    # For production use db-n1-standard-2 or higher.
    tier = var.tier

    # ZONAL for dev (cheaper), REGIONAL for staging/prod (HA with auto-failover).
    availability_type = var.availability_type

    # ---------------------------------------------------------------------------
    # Disk
    # ---------------------------------------------------------------------------
    disk_size             = 20         # GiB — starting size; autoresize handles growth
    disk_type             = "PD_SSD"   # SSD for better IOPS
    disk_autoresize       = true       # Automatically grow disk when usage exceeds threshold
    disk_autoresize_limit = 100        # GiB — cap to control costs; alert if approaching

    # ---------------------------------------------------------------------------
    # IP Configuration — private-only
    # ipv4_enabled=false means no public IP is assigned. All connectivity goes
    # through the private IP in the VPC, which is more secure and avoids
    # public internet exposure.
    # ---------------------------------------------------------------------------
    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = var.vpc_id
      allocated_ip_range                            = var.private_ip_range_name
      enable_private_path_for_google_cloud_services = true
    }

    # ---------------------------------------------------------------------------
    # Backup Configuration
    # Daily backups at 03:00 UTC. PITR allows recovery to any second within the
    # transaction_log_retention_days window. retained_backups=7 keeps one week
    # of snapshots.
    # ---------------------------------------------------------------------------
    backup_configuration {
      enabled                        = true
      start_time                     = "03:00"
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = 7
        retention_unit   = "COUNT"
      }
    }

    # ---------------------------------------------------------------------------
    # Query Insights
    # Provides detailed query performance data in the Cloud Console.
    # Useful for identifying slow queries without a separate APM tool.
    # ---------------------------------------------------------------------------
    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = true
      record_client_address   = true
    }

    # ---------------------------------------------------------------------------
    # Maintenance Window
    # Sunday (day=7), 02:00 UTC — outside typical business hours.
    # update_track=stable reduces the risk of unexpected breaking changes.
    # ---------------------------------------------------------------------------
    maintenance_window {
      day          = 7       # Sunday
      hour         = 2       # 02:00 UTC
      update_track = "stable"
    }

    # ---------------------------------------------------------------------------
    # Database Flags
    # max_connections=100 is appropriate for dev with db-g1-small (512 MB RAM).
    # Increase for larger tiers; use a connection pooler (PgBouncer / Cloud SQL Proxy)
    # before raising this significantly.
    # ---------------------------------------------------------------------------
    database_flags {
      name  = "max_connections"
      value = "100"
    }

    user_labels = merge(var.labels, {
      env     = var.env
      managed = "terraform"
    })
  }
}

# ---------------------------------------------------------------------------
# Databases
# ---------------------------------------------------------------------------

resource "google_sql_database" "payments" {
  provider = google

  name     = "payments"
  instance = google_sql_database_instance.main.name
  project  = var.project_id

  depends_on = [google_sql_database_instance.main]
}

resource "google_sql_database" "temporal" {
  provider = google

  name     = "temporal"
  instance = google_sql_database_instance.main.name
  project  = var.project_id

  depends_on = [google_sql_database_instance.main]
}

resource "google_sql_database" "temporal_visibility" {
  provider = google

  name     = "temporal_visibility"
  instance = google_sql_database_instance.main.name
  project  = var.project_id

  depends_on = [google_sql_database_instance.main]
}

# ---------------------------------------------------------------------------
# Users
#
# Passwords are passed in as sensitive variables — never hardcode passwords.
# In production, generate passwords with a random_password resource and store
# them in Secret Manager. The Cloud SQL Auth Proxy or Workload Identity can
# then provide passwordless access to GKE pods.
# ---------------------------------------------------------------------------

resource "google_sql_user" "payments_api" {
  provider = google

  name     = "payments-api"
  instance = google_sql_database_instance.main.name
  project  = var.project_id
  password = var.db_password

  depends_on = [google_sql_database_instance.main]
}

resource "google_sql_user" "temporal" {
  provider = google

  name     = "temporal"
  instance = google_sql_database_instance.main.name
  project  = var.project_id
  password = var.temporal_db_password

  depends_on = [google_sql_database_instance.main]
}
