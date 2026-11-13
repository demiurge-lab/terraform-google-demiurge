output "ip_address" {
  description = "Without tunnel: point the page's name and its api. and site. names here; the certificate is issued once all three resolve."
  value       = local.lb ? google_compute_global_address.main[0].address : null
}

output "tunnel_secret" {
  description = "With tunnel: the secret to write the tunnel's token to, as a new version."
  value       = var.tunnel ? google_secret_manager_secret.tunnel_token[0].id : null
}

output "names" {
  value = distinct([var.domain, local.api, local.site])
}

output "vm" {
  description = "Reach it with: gcloud compute ssh <vm> --zone <zone> --tunnel-through-iap"
  value       = google_compute_instance.main.name
}

output "reader_email" {
  description = "Create this reader's JSON key outside Terraform and store it as demiurge-gcp-<name>-key in Secret Manager."
  value       = google_service_account.reader.email
}

output "registry" {
  description = "This project's registry: where the customer's build pushes with build_here, or where images named with harness_image and web_image are copied."
  value       = "${var.region}-docker.pkg.dev/${var.project}/${google_artifact_registry_repository.main.repository_id}"
}

output "vm_service_account" {
  description = "Demiurge grants this read access to its registry; the VM waits for it on its first start."
  value       = google_service_account.vm.email
}

output "channels" {
  description = "With build_here: the channels the customer's build moves; else Demiurge's channels."
  value       = local.channels
}

output "exports_bucket" {
  value = google_storage_bucket.exports.name
}

output "next" {
  value = "On the VM: sudo demiurge-admin init --herald <email>, then add your model key in Setup"
}
