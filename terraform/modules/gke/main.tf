# =============================================================================
# GKE Standard Cluster Module — main.tf
# =============================================================================
#
# Provisions a production-grade GKE Standard cluster with:
#   • Workload Identity                  (secure pod-to-GCP auth)
#   • Dataplane V2 / Advanced Datapath   (eBPF networking + built-in NetworkPolicy)
#   • Private nodes, public control plane endpoint
#   • VPC-native (alias IP) networking
#   • Three node pools: system, application, spot
#   • Managed Prometheus + Cloud Logging
#   • Shielded VMs + secure boot on all nodes
#
# =============================================================================

# ---------------------------------------------------------------------------
# GKE Cluster
# ---------------------------------------------------------------------------

resource "google_container_cluster" "main" {
  provider = google

  name               = "${var.name}-${var.env}"
  location           = var.region
  project            = var.project_id
  deletion_protection = false

  # ---------------------------------------------------------------------------
  # We immediately remove the default node pool and manage node pools
  # explicitly via separate google_container_node_pool resources. This gives
  # us full lifecycle control (rolling upgrades, autoscaling per pool, etc.)
  # ---------------------------------------------------------------------------
  remove_default_node_pool = true
  initial_node_count       = 1

  # ---------------------------------------------------------------------------
  # Networking — VPC-native (alias IP) mode required for private cluster
  # ---------------------------------------------------------------------------
  networking_mode = "VPC_NATIVE"
  network         = var.vpc_name
  subnetwork      = var.subnet_name

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # ---------------------------------------------------------------------------
  # Dataplane V2 (Advanced Datapath)
  # Enables eBPF-based networking, built-in NetworkPolicy enforcement,
  # and better observability — no need for a separate CNI or Calico.
  # ---------------------------------------------------------------------------
  datapath_provider = "ADVANCED_DATAPATH"

  # ---------------------------------------------------------------------------
  # Private Cluster Configuration
  # • Nodes get private IPs only (enable_private_nodes)
  # • Control plane endpoint remains public for lab access (enable_private_endpoint=false)
  # • master_authorized_networks_config restricts who can reach that endpoint
  # ---------------------------------------------------------------------------
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.master_authorized_cidr
      display_name = "All (lab)"
    }
  }

  # ---------------------------------------------------------------------------
  # Workload Identity — enables pods to authenticate to GCP APIs using
  # Kubernetes Service Accounts mapped to GCP Service Accounts, eliminating
  # the need for key files on nodes.
  # ---------------------------------------------------------------------------
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # ---------------------------------------------------------------------------
  # Add-ons
  # ---------------------------------------------------------------------------
  addons_config {
    # HTTP(S) Load Balancing — required for Ingress / Gateway API
    http_load_balancing {
      disabled = false
    }

    # Horizontal Pod Autoscaler — required for HPA objects
    horizontal_pod_autoscaling {
      disabled = false
    }

    # Persistent Disk CSI driver — required for StorageClass / PVC provisioning
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  # ---------------------------------------------------------------------------
  # Release Channel — REGULAR gives a balance of stability and recency.
  # Nodes will auto-upgrade within the channel's cadence.
  # ---------------------------------------------------------------------------
  release_channel {
    channel = "REGULAR"
  }

  # ---------------------------------------------------------------------------
  # Cloud Logging — ship both system (kube-system, etc.) and workload logs
  # ---------------------------------------------------------------------------
  logging_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
      "WORKLOADS",
    ]
  }

  # ---------------------------------------------------------------------------
  # Cloud Monitoring — control-plane components + Managed Prometheus
  # Managed Prometheus allows Prometheus-compatible scraping without running
  # your own Prometheus server.
  # ---------------------------------------------------------------------------
  monitoring_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
      "APISERVER",
      "SCHEDULER",
      "CONTROLLER_MANAGER",
    ]

    managed_prometheus {
      enabled = true
    }
  }

  # ---------------------------------------------------------------------------
  # Default node_config for the stub node pool (removed immediately).
  # Must still specify a service account to satisfy the provider schema.
  # ---------------------------------------------------------------------------
  node_config {
    service_account = var.node_sa_email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  # ---------------------------------------------------------------------------
  # Resource labels propagated to the cluster object in GCP
  # ---------------------------------------------------------------------------
  resource_labels = merge(var.labels, {
    env     = var.env
    managed = "terraform"
  })

  lifecycle {
    # Prevent accidental cluster recreation — it would destroy all workloads.
    prevent_destroy = false # Set to true in production
    ignore_changes  = [node_config]
  }
}

# ---------------------------------------------------------------------------
# Node Pool — System
#
# Hosts GKE system components (CoreDNS, kube-proxy, GKE daemonsets, etc.)
# Intentionally kept lean (e2-medium) and separated from workload nodes so
# that system pods are never evicted by noisy application workloads.
# ---------------------------------------------------------------------------

resource "google_container_node_pool" "system" {
  provider = google

  name     = "${var.name}-system"
  location = var.region
  cluster  = google_container_cluster.main.name
  project  = var.project_id

  # Start with one node per zone (regional cluster = 3 zones → 3 nodes)
  node_count = 1

  node_config {
    machine_type = "e2-medium"
    disk_size_gb = 50
    disk_type    = "pd-standard"

    service_account = var.node_sa_email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    # Shielded VMs — verify boot integrity and prevent rootkit installation
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # GKE_METADATA mode ensures pods use Workload Identity (not the node SA)
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = {
      role = "system"
      env  = var.env
    }

    resource_labels = merge(var.labels, {
      role    = "system"
      env     = var.env
      managed = "terraform"
    })
  }

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  depends_on = [google_container_cluster.main]
}

# ---------------------------------------------------------------------------
# Node Pool — Application
#
# General-purpose pool for user workloads. Uses SSD-backed disks for
# better I/O and a slightly larger machine type to handle typical app pods.
# ---------------------------------------------------------------------------

resource "google_container_node_pool" "application" {
  provider = google

  name     = "${var.name}-application"
  location = var.region
  cluster  = google_container_cluster.main.name
  project  = var.project_id

  initial_node_count = 2

  node_config {
    machine_type = "e2-standard-2"
    disk_size_gb = 50
    disk_type    = "pd-standard"

    service_account = var.node_sa_email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = {
      role = "application"
      env  = var.env
    }

    resource_labels = merge(var.labels, {
      role    = "application"
      env     = var.env
      managed = "terraform"
    })
  }

  autoscaling {
    min_node_count = 1
    max_node_count = 5
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  depends_on = [google_container_cluster.main]
}

# ---------------------------------------------------------------------------
# Node Pool — Spot (Preemptible v2)
#
# Cost-optimised pool for fault-tolerant / batch workloads. Spot VMs are
# significantly cheaper but can be reclaimed by GCP at any time.
#
# Convention:
#   • Label  cloud.google.com/gke-spot=true  (matches GKE auto-provisioner)
#   • Taint  cloud.google.com/gke-spot:NoSchedule  so only pods that explicitly
#     tolerate the taint land here — prevents accidental scheduling of
#     latency-sensitive services on preemptible nodes.
#
# Starts at 0 nodes; Cluster Autoscaler scales up on demand.
# ---------------------------------------------------------------------------

resource "google_container_node_pool" "spot" {
  provider = google

  name     = "${var.name}-spot"
  location = var.region
  cluster  = google_container_cluster.main.name
  project  = var.project_id

  initial_node_count = 0

  node_config {
    machine_type = "e2-standard-2"
    disk_size_gb = 100
    disk_type    = "pd-standard"

    # Spot (Preemptible v2) — cheaper than standard preemptible, same caveats
    spot = true

    service_account = var.node_sa_email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = {
      role                        = "spot"
      env                         = var.env
      "cloud.google.com/gke-spot" = "true"
    }

    resource_labels = merge(var.labels, {
      role    = "spot"
      env     = var.env
      managed = "terraform"
    })

    # Taint prevents non-spot-aware pods from landing on these nodes
    taint {
      key    = "cloud.google.com/gke-spot"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }

  autoscaling {
    min_node_count = 0
    max_node_count = 10
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  depends_on = [google_container_cluster.main]
}
