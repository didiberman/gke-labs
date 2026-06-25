# =============================================================================
# Cloud SQL — PostgreSQL 15 Module — outputs.tf
# =============================================================================

output "instance_name" {
  description = "The name of the Cloud SQL instance as it appears in the GCP console and gcloud CLI."
  value       = google_sql_database_instance.main.name
}

output "instance_connection_name" {
  description = "Connection name in the format project:region:instance. Used to configure the Cloud SQL Auth Proxy and Kubernetes sidecar."
  value       = google_sql_database_instance.main.connection_name
}

output "private_ip_address" {
  description = "Private IP address of the Cloud SQL instance within the VPC. Only accessible from resources in the same VPC (or peered networks)."
  value       = google_sql_database_instance.main.private_ip_address
  sensitive   = true
}

output "payments_database_name" {
  description = "Name of the payments application database."
  value       = google_sql_database.payments.name
}

output "temporal_database_name" {
  description = "Name of the Temporal workflow engine database."
  value       = google_sql_database.temporal.name
}

output "temporal_visibility_database_name" {
  description = "Name of the Temporal visibility database (used for workflow search and listing)."
  value       = google_sql_database.temporal_visibility.name
}

output "database_user" {
  description = "Username for the payments-api database user."
  value       = google_sql_user.payments_api.name
}

output "temporal_database_user" {
  description = "Username for the Temporal database user."
  value       = google_sql_user.temporal.name
}

output "connection_info" {
  description = "Consolidated map of connection details for use by other modules or root outputs. private_ip is marked sensitive."
  sensitive   = true
  value = {
    instance_name       = google_sql_database_instance.main.name
    connection_name     = google_sql_database_instance.main.connection_name
    private_ip          = google_sql_database_instance.main.private_ip_address
    payments_db         = google_sql_database.payments.name
    temporal_db         = google_sql_database.temporal.name
    temporal_visibility = google_sql_database.temporal_visibility.name
    payments_user       = google_sql_user.payments_api.name
    temporal_user       = google_sql_user.temporal.name
  }
}
