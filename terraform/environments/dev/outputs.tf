################################################################################
# GKE Labs — Dev Environment Outputs
# Project : gke-labs
# Region  : europe-west1
#
# These outputs surface the most operationally useful values after a successful
# `terraform apply`.  Copy-paste the commands directly into your terminal.
################################################################################

# ------------------------------------------------------------------------------
# GKE Cluster
# ------------------------------------------------------------------------------

output "cluster_name" {
  description = "Name of the GKE cluster created by the gke module."
  value       = module.gke.cluster_name
}

output "cluster_location" {
  description = "Region (or zone) where the GKE cluster is located."
  value       = module.gke.cluster_location
}

output "get_credentials_command" {
  description = <<-EOT
    Run this command to configure kubectl to talk to the new cluster.
    After running it, every subsequent kubectl / helm invocation will target
    the dev cluster automatically.
  EOT
  value = format(
    "gcloud container clusters get-credentials %s --region %s --project %s",
    module.gke.cluster_name,
    var.region,
    var.project_id,
  )
}

# ------------------------------------------------------------------------------
# Observability
# ------------------------------------------------------------------------------

output "grafana_access_command" {
  description = <<-EOT
    Port-forwards the Grafana service to localhost:3000.
    After running the command, open http://localhost:3000 in your browser.
    Default credentials are typically admin / prom-operator (see your Helm values).
  EOT
  value = format(
    "kubectl port-forward -n monitoring svc/%s-grafana 3000:80",
    var.name,
  )
}

# ------------------------------------------------------------------------------
# Cloud SQL (PostgreSQL)
# ------------------------------------------------------------------------------

output "cloud_sql_instance_connection_name" {
  description = <<-EOT
    The Cloud SQL instance connection name in the format
    PROJECT:REGION:INSTANCE_NAME.  Use this value when configuring the
    Cloud SQL Auth Proxy sidecar or when connecting from Cloud Run / GKE.
  EOT
  value = module.cloud_sql.instance_connection_name
}

output "cloud_sql_private_ip" {
  description = "Private IP address of the Cloud SQL instance (accessible from within the VPC)."
  value       = module.cloud_sql.private_ip_address
}

# ------------------------------------------------------------------------------
# Memorystore (Redis)
# ------------------------------------------------------------------------------

output "redis_host" {
  description = "Private IP address of the Redis Memorystore instance."
  value       = module.memorystore.redis_host
}

output "redis_port" {
  description = "Port of the Redis Memorystore instance (default 6379)."
  value       = module.memorystore.redis_port
}

# ------------------------------------------------------------------------------
# Cloud Storage
# ------------------------------------------------------------------------------

output "receipts_bucket" {
  description = "GCS bucket name used to store receipt objects."
  value       = module.storage.receipts_bucket_name
}

output "receipts_bucket_url" {
  description = "Full gs:// URL of the receipts bucket."
  value       = module.storage.receipts_bucket_url
}

# ------------------------------------------------------------------------------
# Artifact Registry
# ------------------------------------------------------------------------------

output "registry_url" {
  description = <<-EOT
    Artifact Registry repository URL.  Use this as the image prefix when
    pushing Docker images, e.g.:
      docker tag myapp:latest REGISTRY_URL/myapp:latest
      docker push REGISTRY_URL/myapp:latest
  EOT
  value = module.iam.registry_url
}

# ------------------------------------------------------------------------------
# Networking
# ------------------------------------------------------------------------------

output "network_name" {
  description = "Name of the shared VPC network."
  value       = module.networking.network_name
}

output "subnetwork_name" {
  description = "Name of the primary GKE subnetwork."
  value       = module.networking.subnetwork_name
}

# ------------------------------------------------------------------------------
# Summary — one-stop overview of the deployed environment
# ------------------------------------------------------------------------------

output "summary" {
  description = "Human-readable summary of all key environment values."
  sensitive   = false
  value       = <<-EOT

    ╔══════════════════════════════════════════════════════════════════╗
    ║            GKE Labs — Dev Environment Summary                   ║
    ╚══════════════════════════════════════════════════════════════════╝

    Project  : ${var.project_id}
    Region   : ${var.region}
    Env      : ${var.env}

    ── GKE ──────────────────────────────────────────────────────────
    Cluster Name : ${module.gke.cluster_name}
    Location     : ${module.gke.cluster_location}
    Kubeconfig   : gcloud container clusters get-credentials ${module.gke.cluster_name} \
                     --region ${var.region} --project ${var.project_id}

    ── Database (Cloud SQL PostgreSQL) ──────────────────────────────
    Connection   : ${module.cloud_sql.instance_connection_name}
    Private IP   : ${module.cloud_sql.private_ip_address}

    ── Cache (Memorystore Redis) ────────────────────────────────────
    Host         : ${module.memorystore.redis_host}:${module.memorystore.redis_port}

    ── Storage (GCS) ────────────────────────────────────────────────
    Receipts     : ${module.storage.receipts_bucket_url}

    ── Container Registry ───────────────────────────────────────────
    Registry URL : ${module.iam.registry_url}

    ── Observability ────────────────────────────────────────────────
    Grafana      : kubectl port-forward -n monitoring svc/${var.name}-grafana 3000:80
                   Then open: http://localhost:3000

    ─────────────────────────────────────────────────────────────────
    Secrets are stored in Google Secret Manager under project:
    ${var.project_id}
    ─────────────────────────────────────────────────────────────────
  EOT
}
