# =============================================================================
# modules/networking/outputs.tf
# =============================================================================

output "vpc_id" {
  description = "The self-link / resource ID of the VPC network."
  value       = google_compute_network.vpc.id
}

output "vpc_name" {
  description = "The name of the VPC network."
  value       = google_compute_network.vpc.name
}

output "subnet_id" {
  description = "The self-link / resource ID of the primary subnet."
  value       = google_compute_subnetwork.main.id
}

output "subnet_name" {
  description = "The name of the primary subnet."
  value       = google_compute_subnetwork.main.name
}

output "pods_range_name" {
  description = "Name of the secondary IP range reserved for GKE Pods. Pass this to the GKE cluster module as var.pods_range_name."
  value       = "${var.name}-pods"
}

output "services_range_name" {
  description = "Name of the secondary IP range reserved for GKE Services (ClusterIPs). Pass this to the GKE cluster module as var.services_range_name."
  value       = "${var.name}-services"
}

output "private_ip_range_name" {
  description = "Name of the global address reservation used for Private Service Access (Cloud SQL, Memorystore peering)."
  value       = google_compute_global_address.private_service_range.name
}

output "router_name" {
  description = "Name of the Cloud Router."
  value       = google_compute_router.nat_router.name
}

output "nat_name" {
  description = "Name of the Cloud NAT gateway."
  value       = google_compute_router_nat.nat.name
}
