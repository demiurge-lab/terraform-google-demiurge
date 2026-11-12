terraform {
  required_version = ">= 1.11"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 7.0" }
    random = { source = "hashicorp/random", version = "~> 3.7" }
  }
}

# The caller configures the google provider for this deployment's project and passes it in (an aliased provider, as
# `providers = { google = google.demiurge }`), so the module can be moved or removed like any other; a precondition
# in main.tf refuses a provider pointed at another project.
