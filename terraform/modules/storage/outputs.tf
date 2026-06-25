# ------------------------------------------------------------------------------
# Module: storage — outputs
# ------------------------------------------------------------------------------

output "receipts_bucket_name" {
  description = "Name of the receipts GCS bucket. Use this to construct gs:// URIs."
  value       = google_storage_bucket.receipts.name
}

output "receipts_bucket_url" {
  description = "gs:// URL of the receipts bucket."
  value       = google_storage_bucket.receipts.url
}

output "backups_bucket_name" {
  description = "Name of the backups GCS bucket."
  value       = google_storage_bucket.backups.name
}

output "backups_bucket_url" {
  description = "gs:// URL of the backups bucket."
  value       = google_storage_bucket.backups.url
}
