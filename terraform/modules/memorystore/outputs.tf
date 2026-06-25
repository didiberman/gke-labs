# ------------------------------------------------------------------------------
# Module: memorystore — outputs
# ------------------------------------------------------------------------------

output "redis_host" {
  description = "IP address of the Redis instance (only accessible from within the authorised VPC)."
  value       = google_redis_instance.this.host
}

output "redis_port" {
  description = "Port number on which the Redis instance is listening."
  value       = google_redis_instance.this.port
}

output "redis_auth_string" {
  description = "Redis AUTH token. Mark sensitive to prevent accidental exposure in logs."
  value       = google_redis_instance.this.auth_string
  sensitive   = true
}

output "instance_id" {
  description = "Full resource name of the Redis instance (projects/…/locations/…/instances/…)."
  value       = google_redis_instance.this.id
}

output "tls_cert" {
  description = "PEM-encoded server CA certificate for TLS verification (SERVER_AUTHENTICATION mode)."
  value       = google_redis_instance.this.server_ca_certs[0].cert
  sensitive   = true
}
