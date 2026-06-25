# ------------------------------------------------------------------------------
# Module: secret-manager — outputs
# ------------------------------------------------------------------------------

output "secret_ids" {
  description = "Map of secret logical name -> full Secret Manager resource ID (projects/{project}/secrets/{secret_id}). Use this to reference secrets in other modules or k8s ExternalSecrets."
  value = {
    for k, s in google_secret_manager_secret.this : k => s.id
  }
}

output "secret_versions" {
  description = "Map of secret logical name -> latest version resource ID. Useful for pinning applications to a specific version."
  value = {
    for k, v in google_secret_manager_secret_version.this : k => v.id
  }
}

output "secret_names" {
  description = "Map of secret logical name -> secret_id (short name, not the full resource path). Convenient for constructing gcloud / API calls."
  value = {
    for k, s in google_secret_manager_secret.this : k => s.secret_id
  }
}
