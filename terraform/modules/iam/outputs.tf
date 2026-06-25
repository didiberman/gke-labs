# =============================================================================
# modules/iam/outputs.tf
# =============================================================================

output "gke_node_sa_email" {
  description = "Email of the GKE node pool service account. Pass to the GKE cluster module as var.node_service_account."
  value       = google_service_account.gke_nodes.email
}

output "gke_node_sa_id" {
  description = "Fully-qualified resource ID (name) of the GKE node SA, e.g. projects/<project>/serviceAccounts/<email>."
  value       = google_service_account.gke_nodes.id
}

output "payments_api_sa_email" {
  description = "Email of the payments-api workload service account. Used in the Kubernetes ServiceAccount annotation: iam.gke.io/gcp-service-account."
  value       = google_service_account.payments_api.email
}

output "payments_api_sa_id" {
  description = "Fully-qualified resource ID of the payments-api SA."
  value       = google_service_account.payments_api.id
}

output "registry_url" {
  description = "Base URL of the Artifact Registry Docker repository, e.g. europe-west1-docker.pkg.dev/<project>/<repo>. Use this as the image prefix in Kubernetes manifests and CI pipelines."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.registry.repository_id}"
}

output "registry_id" {
  description = "Resource ID of the Artifact Registry repository."
  value       = google_artifact_registry_repository.registry.id
}
