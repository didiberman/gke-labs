# =============================================================================
# GKE Standard Cluster Module — outputs.tf
# =============================================================================

output "cluster_name" {
  description = "The name of the GKE cluster as it appears in the GCP console and gcloud CLI."
  value       = google_container_cluster.main.name
}

output "cluster_endpoint" {
  description = "IPv4 address of the GKE control plane endpoint. Used to configure kubectl and the Kubernetes Terraform provider."
  value       = google_container_cluster.main.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64-encoded public certificate authority certificate for the cluster. Required to configure a Kubernetes provider or kubeconfig."
  value       = google_container_cluster.main.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "cluster_id" {
  description = "Fully-qualified resource ID of the GKE cluster (projects/{project}/locations/{location}/clusters/{name})."
  value       = google_container_cluster.main.id
}

output "cluster_location" {
  description = "GCP region (or zone) where the cluster is running."
  value       = google_container_cluster.main.location
}

output "get_credentials_command" {
  description = "Ready-to-run gcloud command to fetch credentials and configure kubectl for this cluster."
  value = format(
    "gcloud container clusters get-credentials %s --region %s --project %s",
    google_container_cluster.main.name,
    google_container_cluster.main.location,
    var.project_id,
  )
}

output "node_pools" {
  description = "Map of node pool names keyed by pool role (system, application, spot)."
  value = {
    system      = google_container_node_pool.system.name
    application = google_container_node_pool.application.name
    spot        = google_container_node_pool.spot.name
  }
}

output "workload_identity_pool" {
  description = "Workload Identity pool for this cluster. Use when binding Kubernetes Service Accounts to GCP Service Accounts."
  value       = "${var.project_id}.svc.id.goog"
}
