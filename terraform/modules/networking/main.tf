# =============================================================================
# modules/networking/main.tf
#
# Provisions a production-ready GCP network stack:
#   - Custom-mode VPC
#   - Regional subnet with GKE secondary IP ranges
#   - Cloud Router + Cloud NAT for private-node egress
#   - Private Service Access (google_service_networking_connection) for
#     Cloud SQL and Memorystore so they can reside on RFC-1918 addresses
#     inside the VPC without public IPs.
# =============================================================================

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0, < 6.0"
    }
  }
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = false # we manage all subnets explicitly
  routing_mode            = "REGIONAL"

  description = "Primary VPC for ${var.name} — managed by Terraform"
}

# ---------------------------------------------------------------------------
# Subnet
# Primary range  : var.subnet_cidr         — GKE node IPs
# Secondary range: pods_range              — GKE Pod CIDR
# Secondary range: services_range          — GKE Service CIDR
# ---------------------------------------------------------------------------
resource "google_compute_subnetwork" "main" {
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.vpc.id
  name          = "${var.name}-subnet"
  ip_cidr_range = var.subnet_cidr

  # Enable Private Google Access so nodes can reach GCP APIs without a NAT
  # public IP for googleapis.com traffic.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "${var.name}-pods"
    ip_cidr_range = "10.16.0.0/14" # 262,144 pod addresses
  }

  secondary_ip_range {
    range_name    = "${var.name}-services"
    ip_cidr_range = "10.20.0.0/20" # 4,096 service ClusterIPs
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }

  description = "Primary subnet for ${var.name} — managed by Terraform"
}

# ---------------------------------------------------------------------------
# Cloud Router  (required by Cloud NAT)
# ---------------------------------------------------------------------------
resource "google_compute_router" "nat_router" {
  project     = var.project_id
  region      = var.region
  network     = google_compute_network.vpc.id
  name        = "${var.name}-router"
  description = "Cloud Router for NAT egress — managed by Terraform"
}

# ---------------------------------------------------------------------------
# Cloud NAT
# Provides outbound internet access for private GKE nodes so they can pull
# container images, OS patches, etc., without a public IP per node.
# ---------------------------------------------------------------------------
resource "google_compute_router_nat" "nat" {
  project                            = var.project_id
  region                             = var.region
  router                             = google_compute_router.nat_router.name
  name                               = "${var.name}-nat"
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ---------------------------------------------------------------------------
# Private Service Access — for Cloud SQL & Memorystore (Managed Services)
#
# Google-managed services (Cloud SQL, Memorystore, etc.) live in a Google-
# owned VPC tenant project. Private Service Access creates a VPC peering
# between your VPC and the Google-managed service VPC, so services get
# RFC-1918 addresses reachable from your GKE nodes without traversing the
# public internet.
#
# Steps:
#   1. Reserve a /16 global internal address block in your VPC.
#   2. Create a service networking connection (VPC peering) using that block.
# ---------------------------------------------------------------------------

# Step 1 — Reserve the private IP allocation range
resource "google_compute_global_address" "private_service_range" {
  project       = var.project_id
  name          = "${var.name}-private-ip-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id

  description = "Address range reserved for Private Service Access (Cloud SQL, Memorystore)"
}

# Step 2 — Establish the VPC peering with Google service networking
resource "google_service_networking_connection" "private_service_connection" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service_range.name]

  # deletion_policy controls what happens to the peering on destroy.
  # ABANDON leaves the peering intact (safe for shared VPCs / long-lived envs);
  # change to "DELETE" if you want full teardown in dev/test environments.
  deletion_policy = "ABANDON"
}

# ---------------------------------------------------------------------------
# Firewall: allow internal traffic within the VPC
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "allow_internal" {
  project     = var.project_id
  network     = google_compute_network.vpc.id
  name        = "${var.name}-allow-internal"
  description = "Allow all traffic between nodes, pods, and services within the VPC"
  priority    = 1000
  direction   = "INGRESS"

  # Covers node subnet + pod CIDR + service CIDR
  source_ranges = [
    var.subnet_cidr,
    "10.16.0.0/14",
    "10.20.0.0/20",
  ]

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
}

# ---------------------------------------------------------------------------
# Firewall: allow GKE control-plane health checks and webhooks
# GKE master nodes communicate on port 443 (admission webhooks) and
# 10250 (kubelet) from the control-plane address range.
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "allow_gke_master" {
  project     = var.project_id
  network     = google_compute_network.vpc.id
  name        = "${var.name}-allow-gke-master"
  description = "Allow GKE control-plane to reach node kubelet and webhooks"
  priority    = 1000
  direction   = "INGRESS"

  # GKE master CIDR is provided per-cluster; this broad range is safe for a
  # lab. In production, scope to the cluster's master_ipv4_cidr_block.
  source_ranges = ["172.16.0.0/28"]

  allow {
    protocol = "tcp"
    ports    = ["443", "8443", "10250"]
  }
}
