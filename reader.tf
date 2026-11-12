resource "google_service_account" "reader" {
  account_id   = "demiurge-reader"
  display_name = "Demiurge's read-only cloud connection"
  depends_on   = [google_project_service.used]
}

resource "google_project_iam_member" "reader" {
  for_each = toset(var.readable_projects)
  project  = each.value
  role     = "roles/viewer"
  member   = "serviceAccount:${google_service_account.reader.email}"
}

resource "google_project_iam_member" "reader_bigquery_data" {
  for_each = toset(var.readable_projects)
  project  = each.value
  role     = "roles/bigquery.dataViewer"
  member   = "serviceAccount:${google_service_account.reader.email}"
}

resource "google_project_iam_member" "reader_bigquery_jobs" {
  for_each = toset(var.readable_projects)
  project  = each.value
  role     = "roles/bigquery.jobUser"
  member   = "serviceAccount:${google_service_account.reader.email}"
}
