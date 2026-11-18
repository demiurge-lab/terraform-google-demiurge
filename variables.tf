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

variable "readable_datasets" {
  description = "BigQuery datasets the reader may query, as project.dataset; the recommended form. Empty grants it every dataset in readable_projects. Leave out any holding regulated data."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for d in var.readable_datasets : can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]\\.[A-Za-z0-9_]{1,1024}$", d))])
    error_message = "Name each dataset as project.dataset, e.g. acme-analytics.events."
  }
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "domain" {
  description = "The page's name, e.g. demiurge.acme.example; api.<domain> and site.<domain> (or site_domain) are Convex's."
  type        = string
}

variable "site_domain" {
  description = "The name for Convex's HTTP actions (Slack's events, the sign-in callbacks, the key set), if not site.<domain>. Behind Cloudflare's proxy, give a first-level name such as demiurge-site.acme.example: Universal SSL covers only one level below the zone."
  type        = string
  default     = null
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
  description = "What to run: a release such as v2026.11.13, pinned by the image digests its release.json records (an update is a change here, which Terraform's plan shows), or, to opt in to unattended updates, a channel such as stable, which the VM follows as Demiurge promotes releases to it: each promotion then runs on the VM, as root, with no review on this side. The VM moves itself onto whatever this names whenever that changes."
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

variable "releases" {
  description = "Where each release's release.json is, naming its images by digest; Demiurge's bucket locks each once published. Terraform reads a pinned release's when it plans, and the VM a channel's release's when it moves, so Demiurge grants both read access."
  type        = string
  default     = "gs://demiurge-releases-modules/releases"
  validation {
    condition     = can(regex("^gs://[^/]+/.*[^/]$", var.releases))
    error_message = "A bucket path, gs://<bucket>/<path>, without a trailing slash."
  }
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

variable "slack_teams" {
  description = "The organisation's Slack workspace (team) ids (docs/slack.md section 8): intellects connect only to these, and sign-ins and messages from any other workspace are refused. Empty accepts any workspace an intellect's owner connects."
  type        = list(string)
  default     = []
}

variable "oidc" {
  description = "The organisation's own sign-in over OIDC, beside Sign in with Slack: its issuer and client id (Google Workspace, Okta, Entra, or Cloudflare Access for SaaS, whose issuer ends in /cdn-cgi/access/sso/oidc/<client id>). A client secret, if the provider wants one, goes in Secret Manager here as demiurge-oidc-client-secret. open_signup lets in anyone it vouches for without an invitation, for a provider limited to the organisation. trust_email takes its email as verified when its tokens don't say (Cloudflare Access; Entra without email_verified), for a provider that checks every email itself."
  type = object({
    issuer      = string
    client_id   = string
    open_signup = optional(bool, false)
    trust_email = optional(bool, false)
  })
  default = null
}

variable "certificate_round" {
  description = "Change to make a fresh certificate (when one stalls unverified)."
  type        = number
  default     = 1
}

variable "tunnel" {
  description = "Reach the deployment through a Cloudflare Tunnel instead of a load balancer: no public address, certificate or load balancer. The caller makes the tunnel (routes: the domain's /api/ paths to http://127.0.0.1:3210 and the rest to :8080, site. to :3211; Convex is served from the page's own name, so one Access cookie covers both) and its DNS, and writes its token to the tunnel_secret output; the VM runs cloudflared with it."
  type        = bool
  default     = false
}

variable "network_logs" {
  description = "Google Cloud's own logs of the deployment's network (docs/deploy.md section 3): Cloud DNS's log of each lookup, the only record of the names intellects look up, sampled VPC flow logs, and Cloud NAT's log of each translation. Off saves their Cloud Logging cost and loses the lookups; the VM's own log of every intellect connection except DNS lookups to the VM's resolver stays."
  type        = bool
  default     = true
}
