# An organisation's Demiurge on its own GCP project (docs/deploy.md): one VM running Convex and the intellects, Cloud SQL
# for Convex's data, one HTTPS load balancer (or a Cloudflare Tunnel) as the only way in, Secret Manager, and a bucket for Convex's exports.
# No secret value passes through Terraform's state: the database password is ephemeral and write-only, and every other
# secret is made on the VM by demiurge-admin.

locals {
  name = "demiurge"
  # With tunnel, Convex is served from the page's own name under /api/, so one Access cookie covers both.
  api      = var.tunnel ? var.domain : "api.${var.domain}"
  site     = "site.${var.domain}"
  instance = "demiurge" # Convex's instance; its database is named after it
  lb       = !var.tunnel
  # A release (v…) pins the deployment; anything else names a channel the VM follows, resolving it itself (follow.sh).
  channel = var.release != null && !can(regex("^v[0-9]", coalesce(var.release, "v0"))) ? var.release : null
  pinned  = local.channel == null ? var.release : null
  # A pinned release's images, from Demiurge's registry, unless images are named outright; a channel's come from the VM.
  # Built here (build_here): the customer's own registry and channel; else Demiurge's.
  registry      = var.build_here ? "${var.region}-docker.pkg.dev/${var.project}/${local.name}" : var.image_registry
  channels      = var.build_here ? "gs://${var.project}-demiurge-channels/channels" : var.channels
  harness_image = var.harness_image != null ? var.harness_image : (local.pinned == null ? "" : "${local.registry}/demiurge-harness:${local.pinned}")
  web_image     = var.web_image != null ? var.web_image : (local.pinned == null ? "" : "${local.registry}/demiurge-web:${local.pinned}")
  services = ["compute.googleapis.com", "sqladmin.googleapis.com", "secretmanager.googleapis.com", "servicenetworking.googleapis.com",
  "iap.googleapis.com", "artifactregistry.googleapis.com", "logging.googleapis.com", "monitoring.googleapis.com", "iam.googleapis.com"]
}

data "google_client_config" "current" {}

resource "google_project_service" "used" {
  for_each           = toset(local.services)
  service            = each.value
  disable_on_destroy = false
  lifecycle {
    precondition {
      condition     = data.google_client_config.current.project == var.project
      error_message = "The google provider passed to this module must be configured for var.project, where everything it makes goes."
    }
  }
}

# ---------- network: private, with outbound through NAT

resource "google_compute_network" "main" {
  name                    = local.name
  auto_create_subnetworks = false
  depends_on              = [google_project_service.used]
}

resource "google_compute_subnetwork" "main" {
  name                     = local.name
  network                  = google_compute_network.main.id
  region                   = var.region
  ip_cidr_range            = "10.20.0.0/24"
  private_ip_google_access = true
}

resource "google_compute_router" "main" {
  name    = local.name
  network = google_compute_network.main.id
  region  = var.region
}

resource "google_compute_router_nat" "main" {
  name                               = local.name
  router                             = google_compute_router.main.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Only Google's load balancer and health checks reach the page and Convex; only IAP reaches SSH.
resource "google_compute_firewall" "load_balancer" {
  count         = local.lb ? 1 : 0
  name          = "${local.name}-load-balancer"
  network       = google_compute_network.main.id
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = [local.name]
  allow {
    protocol = "tcp"
    ports    = ["8080", "3210", "3211"]
  }
}

resource "google_compute_firewall" "iap_ssh" {
  name          = "${local.name}-iap-ssh"
  network       = google_compute_network.main.id
  source_ranges = ["35.235.240.0/20"]
  target_tags   = [local.name]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# ---------- Cloud SQL, over private IP only

resource "google_compute_global_address" "sql" {
  name          = "${local.name}-sql"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.main.id
}

resource "google_service_networking_connection" "sql" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.sql.name]
}

resource "google_sql_database_instance" "main" {
  name                = local.name
  database_version    = "POSTGRES_17"
  region              = var.region
  deletion_protection = true
  depends_on          = [google_service_networking_connection.sql]
  settings {
    tier              = var.db_tier
    availability_type = "ZONAL"
    edition           = "ENTERPRISE"
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.main.id
    }
    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "09:00"
      backup_retention_settings {
        retained_backups = 14
      }
    }
    maintenance_window {
      day  = 7
      hour = 10
    }
  }
}

resource "google_sql_database" "convex" {
  name     = replace(local.instance, "-", "_")
  instance = google_sql_database_instance.main.name
}

# The database password: made here, written to Secret Manager and to Cloud SQL, and kept in neither Terraform's plan
# nor its state. Bump db_password_version to rotate it.
ephemeral "random_password" "db" {
  length  = 40
  special = false
}

variable "db_password_version" {
  type    = number
  default = 1
}

resource "google_secret_manager_secret" "db_password" {
  secret_id = "demiurge-db-password"
  replication {
    auto {}
  }
  depends_on = [google_project_service.used]
}

resource "google_secret_manager_secret_version" "db_password" {
  secret                 = google_secret_manager_secret.db_password.id
  secret_data_wo         = ephemeral.random_password.db.result
  secret_data_wo_version = var.db_password_version
}

resource "google_sql_user" "convex" {
  name                = "demiurge"
  instance            = google_sql_database_instance.main.name
  password_wo         = ephemeral.random_password.db.result
  password_wo_version = var.db_password_version
}

# ---------- the VM

resource "google_service_account" "vm" {
  account_id   = local.name
  display_name = "Demiurge's VM"
  depends_on   = [google_project_service.used]
}

locals {
  vm_roles = ["roles/logging.logWriter", "roles/monitoring.metricWriter", "roles/artifactregistry.reader", "roles/cloudsql.client"]
}

resource "google_project_iam_member" "vm" {
  for_each = toset(local.vm_roles)
  project  = var.project
  role     = each.value
  member   = "serviceAccount:${google_service_account.vm.email}"
}

# demiurge-admin makes and reads its own secrets, all named demiurge-*, and no others.
resource "google_project_iam_member" "vm_secrets" {
  project = var.project
  role    = "roles/secretmanager.admin"
  member  = "serviceAccount:${google_service_account.vm.email}"
  condition {
    title      = "demiurge secrets only"
    expression = "resource.name.startsWith(\"projects/${data.google_project.this.number}/secrets/demiurge-\")"
  }
}

data "google_project" "this" {}

resource "google_compute_disk" "data" {
  name       = "${local.name}-data"
  type       = "pd-balanced"
  zone       = var.zone
  size       = var.data_disk_gb
  depends_on = [google_project_service.used]
}

resource "google_compute_resource_policy" "snapshots" {
  name   = "${local.name}-daily"
  region = var.region
  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = "08:00"
      }
    }
    retention_policy {
      max_retention_days    = 14
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
  }
  depends_on = [google_project_service.used]
}

resource "google_compute_disk_resource_policy_attachment" "snapshots" {
  name = google_compute_resource_policy.snapshots.name
  disk = google_compute_disk.data.name
  zone = var.zone
}

resource "google_compute_instance" "main" {
  name         = local.name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = [local.name]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 30
      type  = "pd-balanced"
    }
  }

  attached_disk {
    source      = google_compute_disk.data.id
    device_name = "demiurge-data"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id # no external address: outbound goes through NAT
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    enable-oslogin = "TRUE"
    # Where the VM says how its last move onto a release went (follow.sh), for deploys to wait on.
    enable-guest-attributes = "TRUE"
    demiurge-follow         = file("${path.module}/follow.sh")
    demiurge-tunnel         = var.tunnel ? "1" : ""
    # The deployment's settings, as demiurge-admin reads them. None is a secret.
    deployment-env = <<-ENV
      ORG_NAME="${var.org_name}"
      TIMEZONE="${var.timezone}"
      SITE_URL="https://${var.domain}"
      CONVEX_CLOUD_ORIGIN="https://${local.api}"
      CONVEX_SITE_ORIGIN="https://${local.site}"
      DASHBOARD_DEPLOYMENT_URL="${var.tunnel ? "http://127.0.0.1:3210" : ""}"
      INSTANCE_NAME="${local.instance}"
      RELEASE="${local.pinned == null ? "" : local.pinned}"
      CHANNEL="${local.channel == null ? "" : local.channel}"
      CHANNELS="${local.channels}"
      IMAGE_REGISTRY="${local.registry}"
      HARNESS_IMAGE="${local.harness_image}"
      WEB_IMAGE="${local.web_image}"
      SECRETS="gcp"
      GCP_PROJECT="${var.project}"
      # Convex reaches Cloud SQL through the Auth Proxy beside it (infra/compose), over TLS from there.
      SQL_CONNECTION="${google_sql_database_instance.main.connection_name}"
      DB_HOST="cloudsql-proxy"
      DO_NOT_REQUIRE_SSL=1
      DB_USER="${google_sql_user.convex.name}"
      LOCAL_DB=0
      BIND="${var.tunnel ? "127.0.0.1" : "0.0.0.0"}"
      EXPORTS_BUCKET="${var.project}-demiurge-exports"
      SPEND_CEILING="${var.spend_ceiling == null ? "" : var.spend_ceiling}"
    ENV
  }
  metadata_startup_script = file("${path.module}/startup.sh")

  allow_stopping_for_update = true
  depends_on                = [google_project_iam_member.vm, google_project_iam_member.vm_secrets]
  lifecycle {
    precondition {
      condition     = var.release != null || (var.harness_image != null && var.web_image != null)
      error_message = "Name a release, or both harness_image and web_image."
    }
  }
}

resource "google_compute_instance_group" "main" {
  count     = local.lb ? 1 : 0
  name      = local.name
  zone      = var.zone
  instances = [google_compute_instance.main.id]
  named_port {
    name = "web"
    port = 8080
  }
  named_port {
    name = "api"
    port = 3210
  }
  named_port {
    name = "site"
    port = 3211
  }
}

# ---------- the load balancer: the only way in

resource "google_compute_global_address" "main" {
  count      = local.lb ? 1 : 0
  name       = local.name
  depends_on = [google_project_service.used]
}

locals {
  backends = {
    web  = { port = "web", path = "/config.json", timeout = 30 }
    api  = { port = "api", path = "/version", timeout = 86400 } # Convex's websocket stays open
    site = { port = "site", path = "/.well-known/jwks.json", timeout = 300 }
  }
}

resource "google_compute_health_check" "main" {
  for_each = local.lb ? local.backends : {}
  name     = "${local.name}-${each.key}"
  http_health_check {
    port_name          = each.value.port
    port_specification = "USE_NAMED_PORT"
    request_path       = each.value.path
  }
  depends_on = [google_project_service.used]
}

resource "google_compute_backend_service" "main" {
  for_each              = local.lb ? local.backends : {}
  name                  = "${local.name}-${each.key}"
  protocol              = "HTTP"
  port_name             = each.value.port
  timeout_sec           = each.value.timeout
  load_balancing_scheme = "EXTERNAL_MANAGED"
  health_checks         = [google_compute_health_check.main[each.key].id]
  backend {
    group           = google_compute_instance_group.main[0].id
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1
  }
  log_config {
    enable = true
  }
}

resource "google_compute_url_map" "main" {
  count           = local.lb ? 1 : 0
  name            = local.name
  default_service = google_compute_backend_service.main["web"].id
  host_rule {
    hosts        = [local.api]
    path_matcher = "api"
  }
  host_rule {
    hosts        = [local.site]
    path_matcher = "site"
  }
  path_matcher {
    name            = "api"
    default_service = google_compute_backend_service.main["api"].id
  }
  path_matcher {
    name            = "site"
    default_service = google_compute_backend_service.main["site"].id
  }
  depends_on = [google_project_service.used]
}

# A generated name, replaced before the old one goes, so the load balancer is never without one: a certificate checked
# before its names pointed here stays unverified until Google next looks, and a fresh one is looked at at once.
resource "random_id" "certificate" {
  count       = local.lb ? 1 : 0
  byte_length = 3
  keepers     = { domains = join(",", [var.domain, local.api, local.site]), round = var.certificate_round }
}

resource "google_compute_managed_ssl_certificate" "main" {
  count = local.lb ? 1 : 0
  name  = "${local.name}-${random_id.certificate[0].hex}"
  managed {
    domains = [var.domain, local.api, local.site]
  }
  lifecycle {
    create_before_destroy = true
  }
  depends_on = [google_project_service.used]
}

resource "google_compute_target_https_proxy" "main" {
  count            = local.lb ? 1 : 0
  name             = local.name
  url_map          = google_compute_url_map.main[0].id
  ssl_certificates = [google_compute_managed_ssl_certificate.main[0].id]
}

resource "google_compute_global_forwarding_rule" "https" {
  count                 = local.lb ? 1 : 0
  name                  = "${local.name}-https"
  target                = google_compute_target_https_proxy.main[0].id
  ip_address            = google_compute_global_address.main[0].id
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

resource "google_compute_url_map" "redirect" {
  count = local.lb ? 1 : 0
  name  = "${local.name}-redirect"
  default_url_redirect {
    https_redirect = true
    strip_query    = false
  }
  depends_on = [google_project_service.used]
}

resource "google_compute_target_http_proxy" "redirect" {
  count   = local.lb ? 1 : 0
  name    = "${local.name}-redirect"
  url_map = google_compute_url_map.redirect[0].id
}

resource "google_compute_global_forwarding_rule" "http" {
  count                 = local.lb ? 1 : 0
  name                  = "${local.name}-http"
  target                = google_compute_target_http_proxy.redirect[0].id
  ip_address            = google_compute_global_address.main[0].id
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# ---------- the release's images: from Demiurge's own registry (var.image_registry), which grants this VM's service
# account read access, or, with build_here, from this registry, where the customer builds them, following a channel in
# this project. Also for images copied in by hand.

resource "google_artifact_registry_repository" "main" {
  repository_id = local.name
  location      = var.region
  format        = "DOCKER"
  depends_on    = [google_project_service.used]
  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
}

resource "google_storage_bucket" "channels" {
  count                       = var.build_here ? 1 : 0
  name                        = "${var.project}-demiurge-channels"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  depends_on                  = [google_project_service.used]
}

resource "google_storage_bucket_iam_member" "channels_vm" {
  count  = var.build_here ? 1 : 0
  bucket = google_storage_bucket.channels[0].name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.vm.email}"
}

# The customer's build identity: pushes images to this registry and moves the channel, and nothing else here.
resource "google_artifact_registry_repository_iam_member" "builders" {
  for_each   = var.build_here ? toset(var.builders) : toset([])
  location   = google_artifact_registry_repository.main.location
  repository = google_artifact_registry_repository.main.name
  role       = "roles/artifactregistry.writer"
  member     = each.value
}

resource "google_storage_bucket_iam_member" "builders" {
  for_each = var.build_here ? toset(var.builders) : toset([])
  bucket   = google_storage_bucket.channels[0].name
  role     = "roles/storage.objectAdmin"
  member   = each.value
}

# ---------- Convex's nightly exports

resource "google_storage_bucket" "exports" {
  name                        = "${var.project}-demiurge-exports"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_storage_bucket_iam_member" "exports" {
  bucket = google_storage_bucket.exports.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.vm.email}"
}

# ---------- with tunnel: the way in instead of the load balancer. The caller makes the tunnel, its routes and DNS, and
# writes the tunnel's token here as a new version; the VM runs cloudflared with it, and nothing listens off the VM.

resource "google_secret_manager_secret" "tunnel_token" {
  count     = var.tunnel ? 1 : 0
  secret_id = "demiurge-tunnel-token"
  replication {
    auto {}
  }
  depends_on = [google_project_service.used]
}

moved {
  from = google_compute_firewall.load_balancer
  to   = google_compute_firewall.load_balancer[0]
}

moved {
  from = google_compute_instance_group.main
  to   = google_compute_instance_group.main[0]
}

moved {
  from = google_compute_global_address.main
  to   = google_compute_global_address.main[0]
}

moved {
  from = google_compute_url_map.main
  to   = google_compute_url_map.main[0]
}

moved {
  from = random_id.certificate
  to   = random_id.certificate[0]
}

moved {
  from = google_compute_managed_ssl_certificate.main
  to   = google_compute_managed_ssl_certificate.main[0]
}

moved {
  from = google_compute_target_https_proxy.main
  to   = google_compute_target_https_proxy.main[0]
}

moved {
  from = google_compute_global_forwarding_rule.https
  to   = google_compute_global_forwarding_rule.https[0]
}

moved {
  from = google_compute_url_map.redirect
  to   = google_compute_url_map.redirect[0]
}

moved {
  from = google_compute_target_http_proxy.redirect
  to   = google_compute_target_http_proxy.redirect[0]
}

moved {
  from = google_compute_global_forwarding_rule.http
  to   = google_compute_global_forwarding_rule.http[0]
}
