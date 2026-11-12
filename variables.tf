variable "project" {
  description = "The organisation's GCP project for Demiurge."
  type        = string
}

variable "region" {
  description = "One region for the VM and Cloud SQL: Convex wants its database close."
  type        = string
  default     = "us-central1"
}

variable "readable_projects" {
  description = "Projects the dedicated reader may inspect and query through a granted Google Cloud connection."
  type        = list(string)
  default     = []
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "domain" {
  description = "The page's name, e.g. demiurge.acme.example; api.<domain> and site.<domain> are Convex's."
  type        = string
}

variable "org_name" {
  description = "The organisation's name, as its intellects say it."
  type        = string
}

variable "timezone" {
  type    = string
  default = "America/Los_Angeles"
}

variable "release" {
  description = "What to run: a channel, such as stable, which the VM follows as Demiurge promotes releases to it (no change here for an update), or a release such as v2026.11.13 to pin one. The VM moves itself onto whatever this names whenever that changes."
  type        = string
  default     = null
}

variable "build_here" {
  description = "Build the images in this project instead of using Demiurge's: the customer builds each release, from its own copy of Demiurge, into this project's registry and moves a channel in its bucket, so the VM runs only what the customer built from code it holds."
  type        = bool
  default     = false
}

variable "builders" {
  description = "With build_here: the identities that build (IAM members, e.g. serviceAccount:<the customer's build account>), granted write on this registry and the channel bucket."
  type        = list(string)
  default     = []
}

variable "channels" {
  description = "Where a channel's current release is named, one object per channel; the VM's service account is granted read on it with the registry."
  type        = string
  default     = "gs://demiurge-releases-public/channels"
}

variable "image_registry" {
  description = "Where release images come from: Demiurge's registry, which grants this deployment's VM service account (demiurge@<project>.iam.gserviceaccount.com) read access."
  type        = string
  default     = "us-docker.pkg.dev/demiurge-releases/releases"
}

variable "harness_image" {
  description = "Instead of release: the harness image by name, for images copied into this project's registry."
  type        = string
  default     = null
}

variable "web_image" {
  description = "Instead of release: the page image by name."
  type        = string
  default     = null
}

variable "machine_type" {
  description = "16 GB: Convex, a few intellects, and a role typechecking and building a large monorepo (docs/roles.md §13). Go up a size when memory stays above about 70%."
  type        = string
  default     = "e2-standard-4"
}

variable "data_disk_gb" {
  type    = number
  default = 100
}

variable "db_tier" {
  description = "Shared-core, which Google's SLA does not cover; db-custom-1-3840 is the smallest that is."
  type        = string
  default     = "db-g1-small"
}

variable "spend_ceiling" {
  description = "The soft monthly ceiling on model spend, in US dollars (docs/enterprise.md section 8); null for none."
  type        = number
  default     = null
}

variable "certificate_round" {
  description = "Change to make a fresh certificate (when one stalls unverified)."
  type        = number
  default     = 1
}
