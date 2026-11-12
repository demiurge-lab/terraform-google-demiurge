# Demiurge on Google Cloud

Terraform for an organisation's own Demiurge: one VM running Convex and the intellects, Cloud SQL for Convex's data, one
HTTPS load balancer as the only way in, Secret Manager, and a bucket for Convex's exports. Published here from each
Demiurge release; pin a commit.

```hcl
provider "google" {
  alias   = "demiurge"
  project = "acme-demiurge"
  region  = "us-central1"
}

module "demiurge" {
  source    = "git::https://github.com/demiurge-lab/terraform-google-demiurge.git?ref=<commit>"
  providers = { google = google.demiurge }

  project  = "acme-demiurge"
  domain   = "demiurge.acme.example"
  org_name = "Acme"
  release  = "stable"
}
```

- **`release`:** a channel such as `stable`, which the VM follows as Demiurge promotes releases (an update needs no
  change here), or a release such as `v2026.11.13` to pin one. The VM moves itself onto whatever it names: Convex is
  exported first, every intellect drained and restarted, everything checked, and the release before put back if not.
- **Access:** the VM pulls Demiurge's images and reads its channel with its own service account, the
  `vm_service_account` output, which Demiurge grants read access; nothing here holds a credential. A new VM waits on its
  first start until that grant is there.
- **The provider** is passed in, configured for `project`; the module refuses one for another project.
- **DNS:** point `domain` and its `api.` and `site.` names at the `ip_address` output, as A records without a proxy.
