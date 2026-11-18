resource "google_service_account" "reader" {
  account_id   = "demiurge-reader"
  display_name = "Demiurge's read-only cloud connection"
  depends_on   = [google_project_service.used]
}

locals {
  reader_roles = ["roles/browser", "roles/serviceusage.serviceUsageViewer", "roles/run.viewer", "roles/compute.viewer",
  "roles/cloudsql.viewer", "roles/logging.viewer", "roles/storage.bucketViewer"]
}

resource "google_project_iam_member" "reader" {
  for_each = { for pair in setproduct(var.readable_projects, local.reader_roles) : "${pair[0]} ${pair[1]}" => pair }
  project  = each.value[0]
  role     = each.value[1]
  member   = "serviceAccount:${google_service_account.reader.email}"
}

resource "google_project_iam_member" "reader_bigquery_data" {
  for_each = toset(length(var.readable_datasets) == 0 ? var.readable_projects : [])
  project  = each.value
  role     = "roles/bigquery.dataViewer"
  member   = "serviceAccount:${google_service_account.reader.email}"
}

resource "google_bigquery_dataset_iam_member" "reader" {
  for_each   = toset(var.readable_datasets)
  project    = split(".", each.value)[0]
  dataset_id = split(".", each.value)[1]
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.reader.email}"
}

resource "google_project_iam_member" "reader_bigquery_jobs" {
  for_each = toset(var.readable_projects)
  project  = each.value
  role     = "roles/bigquery.jobUser"
  member   = "serviceAccount:${google_service_account.reader.email}"
}

# The backend, on the VM, mints the reader's short-lived tokens with the VM's identity, so the reader needs no key.
resource "google_service_account_iam_member" "vm_mints_reader_tokens" {
  service_account_id = google_service_account.reader.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.vm.email}"
}
