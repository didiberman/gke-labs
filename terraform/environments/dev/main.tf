################################################################################
# GKE Labs — Dev Environment Root Module
# Project : gke-labs
# Region  : europe-west1
#
# This file wires together every child module. It is the single source of
# truth for how the individual building-blocks relate to each other.
# Sensitive values (DB password, JWT secret) are generated here via
# random_password so they never have to appear in tfvars.
################################################################################

terraform {
  required_version = ">= 1.7"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # ---------------------------------------------------------------------------
  # Remote state — uncomment once the GCS bucket has been created.
  # Run `gsutil mb -p gke-labs gs://gke-labs-terraform-state` first.
  # ---------------------------------------------------------------------------
  # backend "gcs" {
  #   bucket = "gke-labs-terraform-state"
  #   prefix = "environments/dev"
  # }
}

# ------------------------------------------------------------------------------
# Provider configuration
# Both providers share the same project + region; google-beta is required for
# certain GKE and VPC features that are still in beta.
# ------------------------------------------------------------------------------
provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

################################################################################
# Random secrets — generated once, stored in Terraform state (and Secret
# Manager).  Never check the resulting .tfstate into version control.
################################################################################

# Database password for the payments-api user
resource "random_password" "db_password" {
  length           = 20
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Database password for the temporal user
resource "random_password" "temporal_db_password" {
  length           = 20
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# JWT signing secret: 64 chars, alphanumeric only (Base64-safe)
resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

################################################################################
# Module: Networking
# Creates the VPC, subnets, Cloud NAT, and firewall rules.
################################################################################
module "networking" {
  source = "../../modules/networking"

  project_id = var.project_id
  region     = var.region
  name       = var.name
  labels     = var.labels
}

################################################################################
# Module: IAM
# Creates the GKE node-pool service account, Workload Identity bindings, and
# any custom IAM roles needed by the cluster workloads.
################################################################################
module "iam" {
  source = "../../modules/iam"

  project_id = var.project_id
  name       = var.name
  labels     = var.labels
}

################################################################################
# Module: GKE
# Provisions the Autopilot or Standard GKE cluster inside the VPC created
# by the networking module.
################################################################################
module "gke" {
  source = "../../modules/gke"

  project_id = var.project_id
  region     = var.region
  name       = var.name
  env        = var.env
  labels     = var.labels

  # Networking inputs
  vpc_name            = module.networking.vpc_name
  subnet_name         = module.networking.subnet_name
  pods_range_name     = module.networking.pods_range_name
  services_range_name = module.networking.services_range_name

  # IAM inputs — use the node-pool SA created by the iam module
  node_sa_email = module.iam.gke_node_sa_email

  depends_on = [
    module.networking,
    module.iam,
  ]
}

################################################################################
# Workload Identity binding — payments-api
# Must be created AFTER the GKE cluster because the Workload Identity Pool
# (PROJECT.svc.id.goog) only exists once the cluster is provisioned.
################################################################################
resource "google_service_account_iam_member" "payments_api_workload_identity" {
  service_account_id = module.iam.payments_api_sa_id
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[payments/payments-api]"

  depends_on = [module.gke]
}

################################################################################
# Module: Cloud SQL
# Provisions a PostgreSQL instance with private IP, using the VPC created by
# the networking module.
################################################################################
module "cloud_sql" {
  source = "../../modules/cloud-sql"

  project_id = var.project_id
  region     = var.region
  name       = var.name
  env        = var.env
  labels     = var.labels

  # Networking inputs — Cloud SQL uses Private Service Access
  vpc_id                = module.networking.vpc_id
  private_ip_range_name = module.networking.private_ip_range_name

  # Credentials — generated above, never sourced from tfvars
  db_password          = random_password.db_password.result
  temporal_db_password = random_password.temporal_db_password.result

  depends_on = [
    module.networking,
  ]
}

################################################################################
# Module: Memorystore (Redis)
# Provisions a Redis instance with AUTH enabled, connected to the shared VPC.
################################################################################
module "memorystore" {
  source = "../../modules/memorystore"

  project_id = var.project_id
  region     = var.region
  name       = var.name
  env        = var.env
  labels     = var.labels

  # Networking inputs
  vpc_id                = module.networking.vpc_id
  private_ip_range_name = module.networking.private_ip_range_name

  depends_on = [
    module.networking,
  ]
}

################################################################################
# Module: Storage
# Creates the GCS buckets (receipts, assets, backups, etc.).
################################################################################
module "storage" {
  source = "../../modules/storage"

  project_id           = var.project_id
  region               = var.region
  name                 = var.name
  payments_api_sa_email = module.iam.payments_api_sa_email
  labels               = var.labels
}

################################################################################
# Module: Secret Manager
# Stores all runtime secrets in Google Secret Manager so that applications
# can retrieve them via the Secret Manager API or Workload Identity.
################################################################################
module "secret_manager" {
  source = "../../modules/secret-manager"

  project_id = var.project_id
  name       = var.name
  labels     = var.labels

  # SA that gets secretAccessor on every secret
  accessor_sa_email = module.iam.payments_api_sa_email

  # Secrets sourced from random_password resources and sibling modules
  db_password       = random_password.db_password.result
  jwt_secret        = random_password.jwt_secret.result
  redis_auth_string = module.memorystore.redis_auth_string
}
